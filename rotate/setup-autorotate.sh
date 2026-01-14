#!/bin/bash
set -euo pipefail

# Auto-rotate display + touch (0°/180°) using LIS3DH on Raspberry Pi OS Bookworm
# Usage: sudo ./setup-autorotate.sh <username> <display-output> [touch-device-name]

die() { echo "Error: $*" >&2; exit 1; }

# Validate
[[ $EUID -eq 0 ]] || die "Run with sudo"
[[ -n "${1:-}" && -n "${2:-}" ]] || die "Usage: $0 <username> <display-output> [touch-device-name]"
id "$1" &>/dev/null || die "User '$1' does not exist"

USER_NAME="$1"
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
OUTPUT_NAME="$2"
TOUCH_DEVICE="${3:-}"
PY_SCRIPT="$USER_HOME/rotate-screen.py"
SERVICE_DIR="$USER_HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/autorotate.service"
UDEV_RULE="/etc/udev/rules.d/99-touch-rotation.rules"
USER_ID=$(id -u "$USER_NAME")

echo "Setting up auto-rotate for $USER_NAME on $OUTPUT_NAME"

# Install packages
apt-get update -qq
apt-get install -y -qq wlr-randr python3 python3-pip i2c-tools >/dev/null
pip3 install --quiet --break-system-packages adafruit-circuitpython-lis3dh

# Add user to i2c group
getent group i2c &>/dev/null && usermod -aG i2c "$USER_NAME"

# Auto-detect touch device if not provided
if [[ -z "$TOUCH_DEVICE" ]]; then
    echo "No touch device specified, attempting auto-detect..."
    TOUCH_DEVICE=$(libinput list-devices 2>/dev/null | grep -A1 "Touchscreen\|Touch" | grep "Device:" | head -1 | sed 's/.*Device: *//' || true)
    if [[ -n "$TOUCH_DEVICE" ]]; then
        echo "Detected touch device: $TOUCH_DEVICE"
    else
        echo "Warning: No touch device detected. Touch rotation disabled."
    fi
fi

# Create udev rule for touch rotation (if touch device found)
if [[ -n "$TOUCH_DEVICE" ]]; then
    echo "Creating udev rule for touch rotation..."
    cat > "$UDEV_RULE" <<EOF
# Auto-rotate touch input - managed by setup-autorotate.sh
# Normal orientation (0°)
ACTION=="add|change", SUBSYSTEM=="input", ATTRS{name}=="$TOUCH_DEVICE", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0"
EOF
    udevadm control --reload-rules
    
    # Allow user to update udev rules without password
    echo "$USER_NAME ALL=(root) NOPASSWD: /usr/bin/tee $UDEV_RULE, /usr/bin/udevadm" > /etc/sudoers.d/autorotate
    chmod 440 /etc/sudoers.d/autorotate
fi

# Create rotation script
cat > "$PY_SCRIPT" <<'PYEOF'
#!/usr/bin/env python3
import os, sys, time, subprocess, logging

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(message)s')
log = logging.getLogger()

OUTPUT = os.environ.get("DISPLAY_OUTPUT", "HDMI-A-1")
TOUCH_DEVICE = os.environ.get("TOUCH_DEVICE", "")
UDEV_RULE = "/etc/udev/rules.d/99-touch-rotation.rules"
DEADBAND, HOLD_COUNT, POLL = 2.0, 3, 0.25

MATRIX_0 = "1 0 0 0 1 0"
MATRIX_180 = "-1 0 1 0 -1 1"

try:
    import board, busio, adafruit_lis3dh
    accel = adafruit_lis3dh.LIS3DH_I2C(busio.I2C(board.SCL, board.SDA), address=0x18)
except Exception as e:
    log.error(f"Accelerometer init failed: {e}")
    sys.exit(1)

log.info(f"Started: display={OUTPUT}, touch={TOUCH_DEVICE or 'none'}")
last, stable, count = None, None, 0

def set_rotation(rot):
    transform = "normal" if rot == 0 else "180"
    subprocess.run(["wlr-randr", "--output", OUTPUT, "--transform", transform], check=False)
    if TOUCH_DEVICE:
        matrix = MATRIX_0 if rot == 0 else MATRIX_180
        rule = f'# Auto-rotate touch - current: {rot}°\nACTION=="add|change", SUBSYSTEM=="input", ATTRS{{name}}=="{TOUCH_DEVICE}", ENV{{LIBINPUT_CALIBRATION_MATRIX}}="{matrix}"\n'
        subprocess.run(f'echo \'{rule}\' | sudo tee {UDEV_RULE} >/dev/null', shell=True, check=False)
        subprocess.run(["sudo", "udevadm", "control", "--reload-rules"], check=False)
        subprocess.run(["sudo", "udevadm", "trigger"], check=False)
    log.info(f"Rotated to {rot}°")

# Set initial rotation immediately on startup
try:
    z = accel.acceleration[0]
    if abs(z) >= DEADBAND:
        initial = 180 if z > 0 else 0
        set_rotation(initial)
        last = initial
        log.info(f"Initial rotation set to {initial}°")
    else:
        log.info("Device flat at startup, waiting for tilt...")
except Exception as e:
    log.error(f"Initial rotation check failed: {e}")

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
Description=Auto-rotate display and touch using accelerometer
After=graphical-session.target

[Service]
Environment=DISPLAY_OUTPUT=$OUTPUT_NAME
Environment=TOUCH_DEVICE=$TOUCH_DEVICE
Environment=WAYLAND_DISPLAY=wayland-0
Environment=XDG_RUNTIME_DIR=/run/user/$USER_ID
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

echo "Done. Reboot to activate."