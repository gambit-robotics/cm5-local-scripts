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
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
apt-get install -y -qq chromium curl jq python3 qrencode wlrctl >/dev/null

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
for name in default pointer hand1 hand2 text xterm ibeam vertical-text \
    crosshair move watch wait progress top_left_arrow left_ptr_watch grab \
    grabbing n-resize s-resize e-resize w-resize ne-resize nw-resize \
    se-resize sw-resize ew-resize ns-resize nesw-resize nwse-resize \
    col-resize row-resize sb_h_double_arrow sb_v_double_arrow all-scroll \
    not-allowed no-drop copy alias context-menu help cell zoom-in zoom-out \
    dnd-none dnd-move dnd-copy dnd-link crossed_circle none; do
    [[ "$name" != "left_ptr" ]] && ln -sf left_ptr "$name"
done
chown -R "$KIOSK_USER:$KIOSK_USER" "$(dirname "$CURSOR_THEME_DIR")"

cat > /etc/udev/rules.d/90-gambit-touchscreen-calibration.rules <<'UDEVEOF'
# The DSI panel is mounted/displayed 180 degrees from the kernel touch frame.
# Keep touchscreen coordinates aligned with the rotated Wayland output.
ACTION=="add|change", KERNEL=="event*", ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="-1 0 1 0 -1 1"
UDEVEOF
udevadm control --reload-rules || true
udevadm trigger -s input || true

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
SPLASH_DIR="$USER_HOME/kiosk-splash"
install -d -o "$KIOSK_USER" -g "$KIOSK_USER" "$SPLASH_DIR"
# The image's splash page and state server (image/kiosk-splash, GMBT-1533).
install -m 0644 -o "$KIOSK_USER" -g "$KIOSK_USER" "$REPO_DIR/image/kiosk-splash/index.html" "$SPLASH_DIR/index.html"
install -m 0755 "$REPO_DIR/image/gambit-kiosk-splash-server" /usr/local/bin/gambit-kiosk-splash-server
install -m 0755 "$REPO_DIR/image/gambit-setup-options" /usr/local/sbin/gambit-setup-options
install -m 0644 "$REPO_DIR/image/gambit-setup-options.service" /etc/systemd/system/gambit-setup-options.service
systemctl daemon-reload
systemctl enable gambit-setup-options.service
/usr/local/sbin/gambit-setup-options

# The setup name the splash shows, gambit-setup-<id> from the CPU serial, as
# image-built units have it (GMBT-1471): at every boot before viam-agent, and
# now.
install -m 0755 "$REPO_DIR/image/gambit-setup-name" /usr/local/sbin/gambit-setup-name
install -m 0644 "$REPO_DIR/image/gambit-setup-name.service" /etc/systemd/system/gambit-setup-name.service
systemctl daemon-reload
systemctl enable gambit-setup-name.service
/usr/local/sbin/gambit-setup-name

cat > "$KIOSK_SCRIPT" << 'KIOSK_EOF'
#!/bin/bash

KIOSK_URL="http://127.0.0.1:8765/kiosk/help"
SPLASH_PORT="${SPLASH_PORT:-8764}"
SPLASH_DIR="${SPLASH_DIR:-$HOME/kiosk-splash}"
READY_LOG_INTERVAL=30
WEB_CHECK_INTERVAL="${WEB_CHECK_INTERVAL:-5}"
WEB_FAILURE_LIMIT="${WEB_FAILURE_LIMIT:-3}"
RESTART_REQUESTED="/tmp/gambit-kiosk-restart-requested.$$"
rm -f "$RESTART_REQUESTED"

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

# Kill any existing kiosk chromium (only for this user)
pkill -u "$(whoami)" -f "chromium.*user-data-dir=/tmp/chromium-kiosk" 2>/dev/null || true
pkill -u "$(whoami)" -f "python3 -m http.server $SPLASH_PORT" 2>/dev/null || true
pkill -u "$(whoami)" -f "gambit-kiosk-splash-server.*--port $SPLASH_PORT" 2>/dev/null || true

SPLASH_DIR="$SPLASH_DIR" KIOSK_URL="$KIOSK_URL" gambit-kiosk-splash-server --port "$SPLASH_PORT" >/tmp/gambit-kiosk-splash.log 2>&1 &
SPLASH_PID=$!
trap 'kill "$SPLASH_PID" 2>/dev/null || true; rm -f "$RESTART_REQUESTED"' EXIT

encoded_target="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$KIOSK_URL")"
SPLASH_URL="http://127.0.0.1:${SPLASH_PORT}/?target=${encoded_target}"

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
    "$SPLASH_URL" &
CHROMIUM_PID=$!

echo "Waiting for web server on $KIOSK_URL..."
waited=0
while ! curl -fsS "$KIOSK_URL" >/dev/null 2>&1; do
    sleep 2
    waited=$((waited + 2))
    if (( waited % READY_LOG_INTERVAL == 0 )); then
        echo "Still waiting for web server at $KIOSK_URL (${waited}s)"
    fi
done
echo "Web server ready after ${waited}s."

(
    failures=0
    while kill -0 "$CHROMIUM_PID" 2>/dev/null; do
        sleep "$WEB_CHECK_INTERVAL"
        if curl -fsS "$KIOSK_URL" >/dev/null 2>&1; then
            failures=0
            continue
        fi
        failures=$((failures + 1))
        echo "Kiosk web health check failed (${failures}/${WEB_FAILURE_LIMIT})"
        if (( failures >= WEB_FAILURE_LIMIT )); then
            echo "Kiosk web server unavailable; requesting kiosk restart at splash."
            touch "$RESTART_REQUESTED"
            kill "$CHROMIUM_PID" 2>/dev/null || true
            exit 0
        fi
    done
) &
WATCHDOG_PID=$!
trap 'kill "$SPLASH_PID" "$WATCHDOG_PID" 2>/dev/null || true; rm -f "$RESTART_REQUESTED"' EXIT

# Block on Chromium so systemd can restart the kiosk if the browser exits.
wait "$CHROMIUM_PID"
chromium_status=$?
if [[ -f "$RESTART_REQUESTED" ]]; then
    echo "Exiting nonzero so systemd restarts kiosk at splash."
    exit 1
fi
exit "$chromium_status"
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
Environment=XCURSOR_THEME=invisible-cursor
Environment=XCURSOR_SIZE=1
ExecStart=$KIOSK_SCRIPT
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SERVICE_EOF
chown "$KIOSK_USER:$KIOSK_USER" "$SERVICE_FILE"

# Step 5: Add root-owned recovery for missing user-session kiosk.
echo "Creating kiosk recovery service..."
cat > /usr/local/sbin/gambit-kiosk-recovery <<'RECOVERY_EOF'
#!/usr/bin/env bash
set -euo pipefail

KIOSK_USER="${GAMBIT_KIOSK_USER:-gambitadmin}"
CHECK_INTERVAL="${CHECK_INTERVAL:-10}"
MISSING_LIMIT="${MISSING_LIMIT:-3}"
BOOT_GRACE="${BOOT_GRACE:-45}"
LIGHTDM_RESTART_COOLDOWN="${LIGHTDM_RESTART_COOLDOWN:-60}"

log() {
    systemd-cat -t gambit-kiosk-recovery -p info echo "$*"
}

sleep "$BOOT_GRACE"

missing_count=0
last_restart=0

while true; do
    now="$(date +%s)"

    if ! systemctl is-active --quiet lightdm.service; then
        if (( now - last_restart >= LIGHTDM_RESTART_COOLDOWN )); then
            log "lightdm inactive; restarting display manager"
            systemctl restart lightdm.service || true
            last_restart="$now"
        fi
        missing_count=0
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if pgrep -u "$KIOSK_USER" -f 'chromium.*user-data-dir=/tmp/chromium-kiosk' >/dev/null 2>&1; then
        missing_count=0
        sleep "$CHECK_INTERVAL"
        continue
    fi

    missing_count=$((missing_count + 1))
    log "kiosk browser missing (${missing_count}/${MISSING_LIMIT})"

    if (( missing_count >= MISSING_LIMIT && now - last_restart >= LIGHTDM_RESTART_COOLDOWN )); then
        log "kiosk browser did not recover; restarting lightdm"
        systemctl restart lightdm.service || true
        last_restart="$now"
        missing_count=0
    fi

    sleep "$CHECK_INTERVAL"
done
RECOVERY_EOF
chmod 0755 /usr/local/sbin/gambit-kiosk-recovery

cat > /etc/systemd/system/gambit-kiosk-recovery.service <<'RECOVERY_SERVICE_EOF'
[Unit]
Description=Gambit kiosk display recovery watchdog
After=lightdm.service
Wants=lightdm.service

[Service]
Type=simple
Environment=GAMBIT_KIOSK_USER=__KIOSK_USER__
ExecStart=/usr/local/sbin/gambit-kiosk-recovery
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
RECOVERY_SERVICE_EOF
sed -i "s/__KIOSK_USER__/$KIOSK_USER/g" /etc/systemd/system/gambit-kiosk-recovery.service
systemctl daemon-reload
systemctl enable gambit-kiosk-recovery.service >/dev/null 2>&1 || true

# Step 6: Fix lightdm boot delay (renderD128 often missing on CM5, causes 90s device timeout)
echo "Fixing lightdm boot dependency..."
systemctl mask dev-dri-renderD128.device 2>/dev/null || true

# Step 7: Enable the service
loginctl enable-linger "$KIOSK_USER"
sudo -u "$KIOSK_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user daemon-reload
sudo -u "$KIOSK_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" systemctl --user enable kiosk.service

echo ""
echo "Done! Reboot to start kiosk, or run:"
echo "  sudo -u $KIOSK_USER XDG_RUNTIME_DIR=/run/user/$USER_ID systemctl --user start kiosk.service"
