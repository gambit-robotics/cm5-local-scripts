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
apt-get install -y -qq chromium curl wlrctl >/dev/null

# Step 2: Create invisible cursor theme for touchscreen kiosk
echo "Creating invisible cursor theme..."
CURSOR_THEME_DIR="$USER_HOME/.local/share/icons/invisible-cursor/cursors"
install -d -o "$KIOSK_USER" -g "$KIOSK_USER" "$CURSOR_THEME_DIR"
install -d -o "$KIOSK_USER" -g "$KIOSK_USER" "$(dirname "$CURSOR_THEME_DIR")"

cat > "$(dirname "$CURSOR_THEME_DIR")/index.theme" << 'THEME_EOF'
[Icon Theme]
Name=invisible-cursor
Comment=Transparent cursor for kiosk
THEME_EOF
chown "$KIOSK_USER:$KIOSK_USER" "$(dirname "$CURSOR_THEME_DIR")/index.theme"

# Write a minimal Xcursor file: 1x1 fully transparent image
# Format: header(16) + toc_entry(12) + image_chunk(36) + pixel(4) = 68 bytes
printf '\x58\x63\x75\x72' > "$CURSOR_THEME_DIR/left_ptr"        # magic: "Xcur"
printf '\x10\x00\x00\x00' >> "$CURSOR_THEME_DIR/left_ptr"       # header size: 16
printf '\x00\x00\x01\x00' >> "$CURSOR_THEME_DIR/left_ptr"       # version: 1.0
printf '\x01\x00\x00\x00' >> "$CURSOR_THEME_DIR/left_ptr"       # ntoc: 1
printf '\x02\x00\xfd\xff' >> "$CURSOR_THEME_DIR/left_ptr"       # toc type: image
printf '\x01\x00\x00\x00' >> "$CURSOR_THEME_DIR/left_ptr"       # toc subtype: size 1
printf '\x1c\x00\x00\x00' >> "$CURSOR_THEME_DIR/left_ptr"       # toc position: 28
printf '\x24\x00\x00\x00' >> "$CURSOR_THEME_DIR/left_ptr"       # chunk header: 36
printf '\x02\x00\xfd\xff' >> "$CURSOR_THEME_DIR/left_ptr"       # chunk type: image
printf '\x01\x00\x00\x00' >> "$CURSOR_THEME_DIR/left_ptr"       # nominal size: 1
printf '\x01\x00\x00\x00' >> "$CURSOR_THEME_DIR/left_ptr"       # version: 1
printf '\x01\x00\x00\x00' >> "$CURSOR_THEME_DIR/left_ptr"       # width: 1
printf '\x01\x00\x00\x00' >> "$CURSOR_THEME_DIR/left_ptr"       # height: 1
printf '\x00\x00\x00\x00' >> "$CURSOR_THEME_DIR/left_ptr"       # xhot: 0
printf '\x00\x00\x00\x00' >> "$CURSOR_THEME_DIR/left_ptr"       # yhot: 0
printf '\x00\x00\x00\x00' >> "$CURSOR_THEME_DIR/left_ptr"       # delay: 0
printf '\x00\x00\x00\x00' >> "$CURSOR_THEME_DIR/left_ptr"       # pixel: transparent

# Symlink all standard cursor names to the invisible cursor
cd "$CURSOR_THEME_DIR"
for name in default pointer hand1 hand2 text xterm crosshair move watch wait \
    top_left_arrow left_ptr_watch grab grabbing n-resize s-resize e-resize \
    w-resize ne-resize nw-resize se-resize sw-resize col-resize row-resize \
    all-scroll not-allowed no-drop copy alias context-menu help progress; do
    [[ "$name" != "left_ptr" ]] && ln -sf left_ptr "$name"
done
chown -R "$KIOSK_USER:$KIOSK_USER" "$(dirname "$CURSOR_THEME_DIR")"

# Set invisible cursor in labwc environment (not rc.xml, which the accelerometer manages)
LABWC_ENV="$USER_HOME/.config/labwc/environment"
install -d -o "$KIOSK_USER" -g "$KIOSK_USER" "$(dirname "$LABWC_ENV")"
# Remove any existing XCURSOR lines, then append
if [[ -f "$LABWC_ENV" ]]; then
    sed -i '/^XCURSOR_THEME=/d; /^XCURSOR_SIZE=/d' "$LABWC_ENV"
else
    touch "$LABWC_ENV"
    chown "$KIOSK_USER:$KIOSK_USER" "$LABWC_ENV"
fi
echo "XCURSOR_THEME=invisible-cursor" >> "$LABWC_ENV"
echo "XCURSOR_SIZE=1" >> "$LABWC_ENV"

# Step 3: Replace desktop with splash wallpaper (seamless Plymouth → desktop transition)
echo "Configuring kiosk desktop (removing panel/desktop, adding splash wallpaper)..."
apt-get install -y -qq swaybg >/dev/null

# Back up and replace system autostart - removes pcmanfm-pi (desktop), wf-panel-pi (taskbar)
# Use solid color matching splash background - rotation-proof (no image to flip)
if [[ -f /etc/xdg/labwc/autostart ]] && [[ ! -f /etc/xdg/labwc/autostart.bak ]]; then
    cp /etc/xdg/labwc/autostart /etc/xdg/labwc/autostart.bak
fi
cat > /etc/xdg/labwc/autostart << 'BGEOF'
swaybg -c '#1a1d23' &
/usr/bin/kanshi &
BGEOF

# Step 4: Create start-kiosk.sh
echo "Creating $KIOSK_SCRIPT..."
cat > "$KIOSK_SCRIPT" << 'KIOSK_EOF'
#!/bin/bash

KIOSK_URL="http://127.0.0.1:8765/kiosk/help"
MAX_WAIT=60

echo "Waiting for Wayland display (max 180s)..."
for i in $(seq 1 180); do
    if [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
        echo "Wayland display ready after ${i}s."
        break
    fi
    sleep 1
done

if [[ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
    echo "Error: Wayland display never appeared. Exiting."
    exit 1
fi

# Wait for web server (splash wallpaper stays visible during this wait)
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

# Kill any existing kiosk chromium (only for this user)
pkill -u "$(whoami)" -f "chromium.*user-data-dir=/tmp/chromium-kiosk" 2>/dev/null || true
sleep 1

echo "Launching Chromium kiosk on Wayland..."
chromium \
    --ozone-platform=wayland \
    --touch-events=enabled \
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
    "$KIOSK_URL" &
CHROMIUM_PID=$!

# Block on Chromium so systemd tracks exit status for Restart=on-failure
wait $CHROMIUM_PID
KIOSK_EOF

chmod +x "$KIOSK_SCRIPT"
chown "$KIOSK_USER:$KIOSK_USER" "$KIOSK_SCRIPT"

# Step 4: Create systemd user service
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

# Step 5: Fix lightdm boot delay (renderD128 often missing on CM5, causes 90s device timeout)
echo "Fixing lightdm boot dependency..."
systemctl mask dev-dri-renderD128.device 2>/dev/null || true

# Step 6: Enable the service
loginctl enable-linger "$KIOSK_USER"
sudo -u "$KIOSK_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user daemon-reload
sudo -u "$KIOSK_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user enable kiosk.service

echo ""
echo "Done! Reboot to start kiosk, or run:"
echo "  sudo -u $KIOSK_USER XDG_RUNTIME_DIR=/run/user/$USER_ID systemctl --user start kiosk.service"
