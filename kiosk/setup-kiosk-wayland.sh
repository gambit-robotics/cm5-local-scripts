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

    * {
      box-sizing: border-box;
      caret-color: transparent;
      cursor: none;
      user-select: none;
    }

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

    async function checkReady() {
      try {
        const response = await fetch(`/state?target=${encodeURIComponent(target)}`, { cache: "no-store" });
        const state = await response.json();
        status.textContent = state.message || "Starting Gambit services...";
        if (state.ready) {
          window.location.replace(target);
          return;
        }
      } catch (_) {
        status.textContent = "Starting Gambit services...";
      }
      window.setTimeout(checkReady, 2000);
    }

    window.setTimeout(checkReady, 800);
  </script>
</body>
</html>
SPLASH_EOF
chown "$KIOSK_USER:$KIOSK_USER" "$SPLASH_DIR/index.html"

cat > /usr/local/bin/gambit-kiosk-splash-server <<'PYEOF'
#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import urllib.error
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


def target_ready(url: str) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=0.7):
            return True
    except (OSError, urllib.error.URLError):
        return False


def command_output(args: list[str], timeout: float = 1.0) -> str:
    try:
        return subprocess.run(
            args,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def viam_agent_active() -> bool:
    return command_output(["systemctl", "is-active", "viam-agent.service"]).strip() == "active"


def network_online() -> bool:
    return bool(command_output(["ip", "route", "show", "default"]).strip())


def viam_agent_logs() -> str:
    return command_output(
        ["journalctl", "-u", "viam-agent.service", "-n", "120", "--no-pager"],
        timeout=1.5,
    )


def package_count() -> int:
    package_root = "/root/.viam/packages/data"
    try:
        return len([name for name in os.listdir(package_root) if not name.startswith(".")])
    except OSError:
        return 0


def provisioning_state(target: str) -> dict[str, object]:
    if target_ready(target):
        return {"ready": True, "message": "Opening Gambit..."}

    if not os.path.exists("/etc/viam.json"):
        return {
            "ready": False,
            "message": "Open the Gambit app and connect with Bluetooth to finish setup.",
        }

    if not viam_agent_active():
        return {"ready": False, "message": "Starting Viam services..."}

    if not network_online():
        return {
            "ready": False,
            "message": "Waiting for Wi-Fi. Finish network setup in the Gambit app.",
        }

    logs = viam_agent_logs()
    installing = (
        "Collecting " in logs
        or "Installing collected packages" in logs
        or "Using cached " in logs
        or "Successfully installed" in logs
        or "modmanager" in logs
    )
    if installing or package_count() > 0:
        return {
            "ready": False,
            "message": "Configuring your robot. Downloading modules and dependencies...",
        }

    return {
        "ready": False,
        "message": "Configuring your robot. This can take a few minutes after Wi-Fi setup.",
    }


class Handler(SimpleHTTPRequestHandler):
    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path == "/state":
            target = parse_qs(parsed.query).get("target", [os.environ.get("KIOSK_URL", "")])[0]
            body = json.dumps(provisioning_state(target)).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        return super().do_GET()

    def log_message(self, fmt: str, *args: object) -> None:
        return


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8764)
    args = parser.parse_args()
    os.chdir(os.environ.get("SPLASH_DIR", "/usr/local/share/gambit/kiosk-splash"))
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
PYEOF
chmod 0755 /usr/local/bin/gambit-kiosk-splash-server

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
