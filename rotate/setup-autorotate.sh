#!/bin/bash
set -euo pipefail

# Auto-rotate display (0°/180°) using LIS3DH accelerometer on Raspberry Pi OS Bookworm
# Touch mapping is handled by labwc rc.xml mapToOutput - NOT by this script
# Usage: sudo ./setup-autorotate.sh <username> <display-output>

die() { echo "Error: $*" >&2; exit 1; }

# Validate
[[ $EUID -eq 0 ]] || die "Run with sudo"
[[ -n "${1:-}" && -n "${2:-}" ]] || die "Usage: $0 <username> <display-output>"
id "$1" &>/dev/null || die "User '$1' does not exist"

USER_NAME="$1"
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
OUTPUT_NAME="$2"
PY_SCRIPT="$USER_HOME/rotate-screen.py"
SERVICE_DIR="$USER_HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/autorotate.service"
USER_ID=$(id -u "$USER_NAME")

echo "Setting up display auto-rotate for $USER_NAME on $OUTPUT_NAME"

# Cleanup: Remove old touch udev rules and sudoers entries from previous versions
# This ensures idempotency and removes the double-transform issue
OLD_UDEV_RULE="/etc/udev/rules.d/99-touch-rotation.rules"
OLD_SUDOERS="/etc/sudoers.d/autorotate"
if [[ -f "$OLD_UDEV_RULE" ]]; then
    echo "Removing old touch udev rule (no longer needed)..."
    rm -f "$OLD_UDEV_RULE"
    udevadm control --reload-rules
fi
if [[ -f "$OLD_SUDOERS" ]]; then
    echo "Removing old sudoers entry (no longer needed)..."
    rm -f "$OLD_SUDOERS"
fi

# Install packages (skip apt-get update if called from unified installer)
if [[ "${SKIP_APT_UPDATE:-}" != "1" ]]; then
    apt-get update -qq
fi
apt-get install -y -qq wlr-randr python3 python3-pip i2c-tools >/dev/null
pip3 install --quiet --break-system-packages adafruit-circuitpython-lis3dh

# Add user to i2c group
getent group i2c &>/dev/null && usermod -aG i2c "$USER_NAME"

# Create rotation script (display only - no touch calibration)
# Note: Touch input is mapped via labwc rc.xml <touch mapToOutput="..."/>
# which automatically handles coordinate transformation when display rotates.
# Do NOT use LIBINPUT_CALIBRATION_MATRIX - it causes double-inversion.
cat > "$PY_SCRIPT" <<'PYEOF'
#!/usr/bin/env python3
"""
Auto-rotate display based on LIS3DH accelerometer readings.
Only rotates display output via wlr-randr.
Touch mapping is handled by labwc mapToOutput (not here).
"""
import os, sys, time, subprocess, logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(message)s')
log = logging.getLogger()

OUTPUT = os.environ.get("DISPLAY_OUTPUT", "DSI-2")
DEADBAND, HOLD_COUNT, POLL = 2.0, 3, 0.25

try:
    import board, busio, adafruit_lis3dh
    accel = adafruit_lis3dh.LIS3DH_I2C(busio.I2C(board.SCL, board.SDA), address=0x18)
except Exception as e:
    log.error(f"Accelerometer init failed: {e}")
    sys.exit(1)

log.info(f"Started: display={OUTPUT} (touch handled by labwc mapToOutput)")
last, stable, count = None, None, 0

def set_rotation(rot):
    """Rotate display only. Touch follows via labwc mapToOutput."""
    transform = "normal" if rot == 0 else "180"
    subprocess.run(["wlr-randr", "--output", OUTPUT, "--transform", transform], check=False)
    log.info(f"Display rotated to {rot}°")

def wait_for_display():
    """Wait for Wayland display to be ready - no timeout, keeps trying"""
    attempt = 0
    while True:
        attempt += 1
        try:
            result = subprocess.run(["wlr-randr"], capture_output=True, timeout=2)
            if result.returncode == 0:
                log.info(f"Display ready after {attempt} attempts")
                return True
        except subprocess.TimeoutExpired:
            pass
        if attempt % 30 == 0:
            log.info(f"Still waiting for display... ({attempt}s)")
        time.sleep(1)

# Wait for display before setting initial rotation (waits forever)
wait_for_display()

# Set initial rotation (use reading if clear, else default to 0°)
try:
    z = accel.acceleration[0]
    if abs(z) >= DEADBAND:
        initial = 180 if z > 0 else 0
    else:
        initial = 0  # Default when flat
        log.info("Device flat at startup, defaulting to 0°")
    set_rotation(initial)
    last = initial
    log.info(f"Initial rotation set to {initial}°")
except Exception as e:
    log.error(f"Initial rotation check failed: {e}")
    set_rotation(0)  # Fallback default
    last = 0

while True:
    try:
        # X axis: positive=dock, negative=stove
        # Current logic: positive→0°, negative→180°
        # If screen is upside-down in either position, flip the condition on next line
        z = accel.acceleration[0]
        target = None if abs(z) < DEADBAND else (180 if z > 0 else 0)

        if target is None:
            stable, count = None, 0
        elif target == stable:
            count += 1
        else:
            stable, count = target, 1

        if count >= HOLD_COUNT and target != last:
            set_rotation(target)
            last = target
    except Exception as e:
        log.error(f"Read error: {e}")

    time.sleep(POLL)
PYEOF

chmod +x "$PY_SCRIPT"
chown "$USER_NAME:$USER_NAME" "$PY_SCRIPT"

# Create systemd service
install -d -o "$USER_NAME" -g "$USER_NAME" "$SERVICE_DIR"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Auto-rotate display using accelerometer
After=graphical-session.target

[Service]
Environment=DISPLAY_OUTPUT=$OUTPUT_NAME
Environment=WAYLAND_DISPLAY=wayland-0
Environment=XDG_RUNTIME_DIR=/run/user/$USER_ID
ExecStartPre=/bin/sleep 3
ExecStart=/usr/bin/python3 $PY_SCRIPT
Restart=on-failure

[Install]
WantedBy=default.target
EOF
chown "$USER_NAME:$USER_NAME" "$SERVICE_FILE"

# Enable service
loginctl enable-linger "$USER_NAME"
sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
    systemctl --user daemon-reload
sudo -u "$USER_NAME" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
    systemctl --user enable autorotate.service

echo ""
echo "Done. Display auto-rotate configured for $OUTPUT_NAME"
echo "Note: Touch mapping relies on labwc rc.xml mapToOutput - no udev rules needed."
echo "Reboot to activate."
