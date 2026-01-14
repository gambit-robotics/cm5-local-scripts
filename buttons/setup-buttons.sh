#!/bin/bash
set -euo pipefail

# I2C Button Controller for Arduino Modulino Buttons (ABX00110)
# Controls volume up/down with repeat-while-held, LED feedback
# Usage: sudo ./setup-buttons.sh <username>

die() { echo "Error: $*" >&2; exit 1; }

# Validate
[[ $EUID -eq 0 ]] || die "Run with sudo"
[[ -n "${1:-}" ]] || die "Usage: $0 <username>"
id "$1" &>/dev/null || die "User '$1' does not exist"

USER_NAME="$1"
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
PY_SCRIPT="$USER_HOME/button-controller.py"
SERVICE_DIR="$USER_HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/buttons.service"
USER_ID=$(id -u "$USER_NAME")

echo "Setting up I2C button controller for $USER_NAME"

# Install packages
apt-get update -qq
apt-get install -y -qq python3 python3-smbus i2c-tools alsa-utils >/dev/null

# Add user to i2c group
getent group i2c &>/dev/null && usermod -aG i2c "$USER_NAME"

# Check I2C is enabled
if [[ ! -e /dev/i2c-1 ]]; then
    echo "Warning: /dev/i2c-1 not found. Enable I2C via raspi-config if needed."
fi

# Create button controller script
cat > "$PY_SCRIPT" <<'PYEOF'
#!/usr/bin/env python3
"""I2C Volume Controller for Arduino Modulino Buttons"""
import os
import sys
import time
import subprocess
import logging
import signal

try:
    import smbus2
except ImportError:
    import smbus as smbus2

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(message)s')
log = logging.getLogger()

# Configuration
I2C_ADDR = int(os.environ.get("BUTTON_I2C_ADDR", "0x3E"), 16)
VOLUME_STEP = int(os.environ.get("VOLUME_STEP", "5"))
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "0.05"))
ALSA_MIXER = os.environ.get("ALSA_MIXER", "Speaker")

# Timing
REPEAT_DELAY = 0.4    # Initial delay before repeat
REPEAT_RATE = 0.2     # 200ms between repeats

class ButtonController:
    def __init__(self):
        self.bus = smbus2.SMBus(1)
        self.running = True

        # Button state tracking
        self.button_states = [False, False, False]
        self.button_press_times = [0.0, 0.0, 0.0]
        self.button_last_repeat = [0.0, 0.0, 0.0]

        # Button A = volume up, Button B = unused, Button C = volume down
        self.actions = ["volume_up", None, "volume_down"]

        signal.signal(signal.SIGTERM, self._shutdown)
        signal.signal(signal.SIGINT, self._shutdown)

        # Validate I2C device is accessible
        try:
            self.bus.read_i2c_block_data(I2C_ADDR, 0, 4)
            log.info(f"Started: I2C=0x{I2C_ADDR:02x}, mixer={ALSA_MIXER}, step={VOLUME_STEP}%")
        except OSError as e:
            log.error(f"Cannot reach I2C device 0x{I2C_ADDR:02x}: {e}")
            log.error("Check: i2cdetect -y 1")
            raise

    def _shutdown(self, signum, frame):
        log.info("Shutting down...")
        self.running = False
        self.set_leds(0, 0, 0)

    def read_buttons(self):
        """Read button states from Modulino (skip pinstrap byte)"""
        try:
            data = self.bus.read_i2c_block_data(I2C_ADDR, 0, 4)
            return [bool(data[1]), bool(data[2]), bool(data[3])]
        except Exception as e:
            log.error(f"I2C read error: {e}")
            return [False, False, False]

    def set_leds(self, a, b, c):
        """Set LED states (0=off, 1=on)"""
        try:
            self.bus.write_i2c_block_data(I2C_ADDR, 0, [int(a), int(b), int(c)])
        except Exception as e:
            log.error(f"I2C write error: {e}")

    def volume_up(self):
        subprocess.run(["amixer", "sset", ALSA_MIXER, f"{VOLUME_STEP}%+"],
                       capture_output=True, check=False)
        log.info("Volume +")

    def volume_down(self):
        subprocess.run(["amixer", "sset", ALSA_MIXER, f"{VOLUME_STEP}%-"],
                       capture_output=True, check=False)
        log.info("Volume -")

    def handle_action(self, action, button_idx, now):
        """Handle button action"""
        if action == "volume_up":
            self.volume_up()
        elif action == "volume_down":
            self.volume_down()
        self.button_last_repeat[button_idx] = now

    def run(self):
        while self.running:
            now = time.time()
            buttons = self.read_buttons()
            leds = [0, 0, 0]

            for i, pressed in enumerate(buttons):
                action = self.actions[i]
                was_pressed = self.button_states[i]

                # Skip unused buttons
                if action is None:
                    self.button_states[i] = pressed
                    continue

                # Button just pressed
                if pressed and not was_pressed:
                    self.button_press_times[i] = now
                    self.button_last_repeat[i] = now
                    self.handle_action(action, i, now)

                # Button held - repeat volume adjustment
                elif pressed and was_pressed:
                    hold_time = now - self.button_press_times[i]
                    repeat_elapsed = now - self.button_last_repeat[i]
                    if hold_time > REPEAT_DELAY and repeat_elapsed >= REPEAT_RATE:
                        self.handle_action(action, i, now)

                # LED feedback: on while pressed
                if pressed:
                    leds[i] = 1

                self.button_states[i] = pressed

            self.set_leds(*leds)
            time.sleep(POLL_INTERVAL)

        self.set_leds(0, 0, 0)

if __name__ == "__main__":
    try:
        controller = ButtonController()
        controller.run()
    except Exception as e:
        log.error(f"Fatal error: {e}")
        sys.exit(1)
PYEOF

chmod +x "$PY_SCRIPT"
chown "$USER_NAME:$USER_NAME" "$PY_SCRIPT"

# Create systemd service
install -d -o "$USER_NAME" -g "$USER_NAME" "$SERVICE_DIR"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=I2C Button Controller (Volume)
After=multi-user.target

[Service]
Environment=BUTTON_I2C_ADDR=0x3E
Environment=VOLUME_STEP=5
Environment=POLL_INTERVAL=0.05
Environment=ALSA_MIXER=Speaker
ExecStart=/usr/bin/python3 $PY_SCRIPT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
chown "$USER_NAME:$USER_NAME" "$SERVICE_FILE"

# Enable service
loginctl enable-linger "$USER_NAME"
sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
    systemctl --user daemon-reload
sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
    systemctl --user enable buttons.service

echo ""
echo "Done. Service enabled for $USER_NAME."
echo ""
echo "Button mapping:"
echo "  A = Volume Up"
echo "  B = (unused)"
echo "  C = Volume Down"
echo ""
echo "Commands:"
echo "  systemctl --user start buttons    # Start now"
echo "  systemctl --user status buttons   # Check status"
echo "  journalctl --user -u buttons -f   # View logs"
echo ""
echo "Test I2C connection with: i2cdetect -y 1"
