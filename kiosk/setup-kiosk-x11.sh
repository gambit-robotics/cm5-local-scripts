#!/bin/bash
set -euo pipefail

# Kiosk Setup Script for Chef Display (X11)
# For systems running X11/Xorg
# Run with: sudo ./setup-kiosk-x11.sh <username>

die() { echo "Error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo"
[[ -n "${1:-}" ]] || die "Usage: $0 <username>"
id "$1" &>/dev/null || die "User '$1' does not exist"

KIOSK_USER="$1"
USER_HOME=$(getent passwd "$KIOSK_USER" | cut -d: -f6)
USER_ID=$(id -u "$KIOSK_USER")
KIOSK_SCRIPT="$USER_HOME/start-kiosk.sh"
SERVICE_FILE="/etc/systemd/system/kiosk.service"

echo "Setting up X11 kiosk for user: $KIOSK_USER"

# Step 1: Install dependencies (skip apt-get update if called from unified installer)
echo "Installing dependencies..."
if [[ "${SKIP_APT_UPDATE:-}" != "1" ]]; then
    apt-get update -qq
fi
apt-get install -y -qq chromium unclutter curl xdotool >/dev/null

# Step 2: Create start-kiosk.sh
echo "Creating $KIOSK_SCRIPT..."
cat > "$KIOSK_SCRIPT" << 'KIOSK_EOF'
#!/bin/bash

KIOSK_URL="http://127.0.0.1:8765/kiosk/help"
MAX_WAIT=60

export DISPLAY=:0
export XAUTHORITY="${HOME}/.Xauthority"

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

echo "Waiting for X display server..."
for i in {1..30}; do
    if xset q &>/dev/null; then
        echo "X display server ready."
        break
    fi
    sleep 1
done

# Disable screensaver and power management
xset s off 2>/dev/null || true
xset s noblank 2>/dev/null || true
xset -dpms 2>/dev/null || true

# Hide mouse cursor
unclutter -idle 0.5 -root &>/dev/null &

# Kill any existing kiosk chromium (only for this user)
pkill -u "$(whoami)" -f "chromium.*user-data-dir=/tmp/chromium-kiosk" 2>/dev/null || true
sleep 1

echo "Launching Chromium kiosk on X11..."
exec chromium \
    --password-store=basic \
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

# Step 3: Create systemd service
echo "Creating systemd service..."
cat > "$SERVICE_FILE" << SERVICE_EOF
[Unit]
Description=Chef Display Kiosk (X11)
After=network-online.target graphical.target
Wants=network-online.target

[Service]
User=$KIOSK_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=$USER_HOME/.Xauthority
ExecStartPre=/bin/sleep 5
ExecStart=$KIOSK_SCRIPT
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
Type=simple

[Install]
WantedBy=graphical.target
SERVICE_EOF

# Step 4: Enable the service
systemctl daemon-reload
systemctl enable kiosk.service

echo ""
echo "Done! Reboot to start kiosk, or run:"
echo "  sudo systemctl start kiosk.service"
