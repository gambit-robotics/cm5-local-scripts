#!/bin/bash
set -euo pipefail

# Kiosk Setup Script for Chef Display (Wayland/labwc)
# For Raspberry Pi OS Bookworm with Wayland
# Run with: sudo ./setup-kiosk-wayland.sh <username>

die() { echo "Error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo"
[[ -n "${1:-}" ]] || die "Usage: $0 <username>"
id "$1" &>/dev/null || die "User '$1' does not exist"

KIOSK_USER="$1"
USER_HOME=$(getent passwd "$KIOSK_USER" | cut -d: -f6)
USER_ID=$(id -u "$KIOSK_USER")
KIOSK_SCRIPT="$USER_HOME/start-kiosk.sh"
SERVICE_DIR="$USER_HOME/.config/systemd/user"
SERVICE_FILE="$SERVICE_DIR/kiosk.service"

echo "Setting up Wayland kiosk for user: $KIOSK_USER"

# Step 1: Install dependencies (skip apt-get update if called from unified installer)
echo "Installing dependencies..."
if [[ "${SKIP_APT_UPDATE:-}" != "1" ]]; then
    apt-get update -qq
fi
apt-get install -y -qq chromium curl >/dev/null

# Step 2: Create start-kiosk.sh
echo "Creating $KIOSK_SCRIPT..."
cat > "$KIOSK_SCRIPT" << 'KIOSK_EOF'
#!/bin/bash

KIOSK_URL="http://127.0.0.1:8765/kiosk/help"
MAX_WAIT=60

echo "Waiting for web server on $KIOSK_URL (max ${MAX_WAIT}s)..."
waited=0
while ! curl -s "$KIOSK_URL" > /dev/null; do
    sleep 2
    waited=$((waited + 2))
    if [[ $waited -ge $MAX_WAIT ]]; then
        echo "Warning: Web server not ready after ${MAX_WAIT}s, continuing anyway..."
        break
    fi
done
echo "Web server check complete."

echo "Waiting for Wayland display..."
for i in {1..30}; do
    if [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
        echo "Wayland display ready."
        break
    fi
    sleep 1
done

# Kill any existing kiosk chromium (only for this user)
pkill -u "$(whoami)" -f "chromium.*user-data-dir=/tmp/chromium-kiosk" 2>/dev/null || true
sleep 1

echo "Launching Chromium kiosk on Wayland..."
exec chromium \
    --ozone-platform=wayland \
    --noerrdialogs \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --disable-restore-session-state \
    --kiosk \
    --incognito \
    --user-data-dir=/tmp/chromium-kiosk \
    --disable-features=TranslateUI \
    --disable-component-extensions-with-background-pages \
    --disable-background-timer-throttling \
    --disable-renderer-backgrounding \
    --disable-backgrounding-occluded-windows \
    --disable-ipc-flooding-protection \
    "$KIOSK_URL"
KIOSK_EOF

chmod +x "$KIOSK_SCRIPT"
chown "$KIOSK_USER:$KIOSK_USER" "$KIOSK_SCRIPT"

# Step 3: Create systemd user service
echo "Creating systemd user service..."
install -d -o "$KIOSK_USER" -g "$KIOSK_USER" "$SERVICE_DIR"
cat > "$SERVICE_FILE" << SERVICE_EOF
[Unit]
Description=Chef Display Kiosk (Wayland)
After=graphical-session.target

[Service]
Environment=WAYLAND_DISPLAY=wayland-0
Environment=XDG_RUNTIME_DIR=/run/user/$USER_ID
ExecStart=$KIOSK_SCRIPT
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SERVICE_EOF
chown "$KIOSK_USER:$KIOSK_USER" "$SERVICE_FILE"

# Step 4: Enable the service
loginctl enable-linger "$KIOSK_USER"
sudo -u "$KIOSK_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user daemon-reload
sudo -u "$KIOSK_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user enable kiosk.service

echo ""
echo "Done! Reboot to start kiosk, or run:"
echo "  sudo -u $KIOSK_USER XDG_RUNTIME_DIR=/run/user/$USER_ID systemctl --user start kiosk.service"
