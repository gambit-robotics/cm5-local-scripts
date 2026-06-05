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
apt-get install -y -qq chromium curl python3 wlrctl >/dev/null

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
SPLASH_DIR="$USER_HOME/kiosk-splash"
install -d -o "$KIOSK_USER" -g "$KIOSK_USER" "$SPLASH_DIR"
cat > "$SPLASH_DIR/index.html" <<'SPLASH_EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Starting Gambit</title>
  <style>
    :root {
      color-scheme: dark;
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #1a1d23;
      color: #f5f7fb;
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background:
        radial-gradient(circle at 50% 35%, rgba(63, 96, 142, 0.24), transparent 34%),
        #1a1d23;
    }

    main {
      width: min(86vw, 560px);
      text-align: center;
    }

    h1 {
      margin: 0;
      font-size: clamp(2.4rem, 8vw, 4.2rem);
      font-weight: 650;
      letter-spacing: 0;
    }

    p {
      margin: 1.2rem 0 0;
      color: #c6cedc;
      font-size: clamp(1.15rem, 3vw, 1.55rem);
      line-height: 1.45;
    }

    .bar {
      position: relative;
      overflow: hidden;
      width: min(70vw, 380px);
      height: 10px;
      margin: 2.2rem auto 0;
      border-radius: 999px;
      background: rgba(255, 255, 255, 0.14);
    }

    .bar::after {
      content: "";
      position: absolute;
      inset: 0;
      width: 42%;
      border-radius: inherit;
      background: #7ea4ff;
      animation: loading 1.35s ease-in-out infinite;
    }

    @keyframes loading {
      0% { transform: translateX(-100%); }
      100% { transform: translateX(240%); }
    }
  </style>
</head>
<body>
  <main>
    <h1>Starting Gambit</h1>
    <p id="status">Starting local services...</p>
    <div class="bar" aria-hidden="true"></div>
  </main>
  <script>
    const target = new URLSearchParams(window.location.search).get("target") || "http://127.0.0.1:8765/kiosk/help";
    const status = document.getElementById("status");
    let attempts = 0;

    async function checkReady() {
      attempts += 1;
      if (attempts > 10) {
        status.textContent = "Still starting. This can take a few minutes after setup.";
      }

      try {
        await fetch(target, { cache: "no-store", mode: "no-cors" });
        window.location.replace(target);
      } catch (_) {
        window.setTimeout(checkReady, 2000);
      }
    }

    window.setTimeout(checkReady, 800);
  </script>
</body>
</html>
SPLASH_EOF
chown "$KIOSK_USER:$KIOSK_USER" "$SPLASH_DIR/index.html"

cat > "$KIOSK_SCRIPT" << 'KIOSK_EOF'
#!/bin/bash

KIOSK_URL="http://127.0.0.1:8765/kiosk/help"
SPLASH_PORT="${SPLASH_PORT:-8764}"
SPLASH_DIR="${SPLASH_DIR:-$HOME/kiosk-splash}"
READY_LOG_INTERVAL=30
WEB_CHECK_INTERVAL="${WEB_CHECK_INTERVAL:-5}"
WEB_FAILURE_LIMIT="${WEB_FAILURE_LIMIT:-3}"

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

python3 -m http.server "$SPLASH_PORT" --bind 127.0.0.1 --directory "$SPLASH_DIR" >/tmp/gambit-kiosk-splash.log 2>&1 &
SPLASH_PID=$!
trap 'kill "$SPLASH_PID" 2>/dev/null || true' EXIT

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
            echo "Kiosk web server unavailable; restarting Chromium at splash."
            kill "$CHROMIUM_PID" 2>/dev/null || true
            exit 0
        fi
    done
) &
WATCHDOG_PID=$!
trap 'kill "$SPLASH_PID" "$WATCHDOG_PID" 2>/dev/null || true' EXIT

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
Environment=XCURSOR_THEME=invisible-cursor
Environment=XCURSOR_SIZE=1
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
