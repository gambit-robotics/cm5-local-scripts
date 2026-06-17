#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ROOTFS=""
BOOTFS=""
IMAGE_VERSION=""
VIAM_DEFAULTS=""
TARGET_USER="gambitadmin"

usage() {
    cat <<'EOF'
Usage: image/apply-rootfs.sh --rootfs PATH --bootfs PATH --image-version VERSION [options]

Options:
  --rootfs PATH          Mounted root filesystem for the image.
  --bootfs PATH          Mounted boot firmware filesystem for the image.
  --image-version VALUE  Image version to write to /etc/gambit/image-build.json.
  --viam-defaults PATH   viam-defaults.json to bake into /etc for BLE provisioning.
  --target-user NAME     User service template owner/name hint (default: gambitadmin).
  --help                 Show this help.

This script writes runtime artifacts into a mounted Raspberry Pi OS rootfs. It
does not mount images, install apt packages, or bake any per-device secret.
The image must include Viam provisioning defaults, but must not include
per-device /etc/viam.json cloud credentials.
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootfs) ROOTFS="${2:-}"; shift 2 ;;
        --bootfs) BOOTFS="${2:-}"; shift 2 ;;
        --image-version) IMAGE_VERSION="${2:-}"; shift 2 ;;
        --viam-defaults) VIAM_DEFAULTS="${2:-}"; shift 2 ;;
        --target-user) TARGET_USER="${2:-}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$ROOTFS" ]] || die "--rootfs is required"
[[ -n "$BOOTFS" ]] || die "--bootfs is required"
[[ -n "$IMAGE_VERSION" ]] || die "--image-version is required"
[[ -d "$ROOTFS" ]] || die "rootfs does not exist: $ROOTFS"
[[ -d "$BOOTFS" ]] || die "bootfs does not exist: $BOOTFS"
[[ -f "$ROOTFS/etc/os-release" ]] || die "rootfs does not look mounted: missing $ROOTFS/etc/os-release"
[[ -n "$TARGET_USER" ]] || die "--target-user must be non-empty"
[[ -n "$VIAM_DEFAULTS" ]] || die "--viam-defaults is required for a provisionable image"
[[ -f "$VIAM_DEFAULTS" ]] || die "--viam-defaults file not found: $VIAM_DEFAULTS"

install_file() {
    local mode="$1"
    local src="$2"
    local dst="$3"
    install -d -m 0755 "$(dirname "$dst")"
    install -m "$mode" "$src" "$dst"
}

write_file() {
    local mode="$1"
    local dst="$2"
    install -d -m 0755 "$(dirname "$dst")"
    cat > "$dst"
    chmod "$mode" "$dst"
}

enable_system_unit() {
    local unit="$1"
    install -d -m 0755 "$ROOTFS/etc/systemd/system/multi-user.target.wants"
    ln -sfn "../$unit" "$ROOTFS/etc/systemd/system/multi-user.target.wants/$unit"
}

mask_system_unit() {
    local unit="$1"
    install -d -m 0755 "$ROOTFS/etc/systemd/system"
    ln -sfn /dev/null "$ROOTFS/etc/systemd/system/$unit"
}

cm5_ref="$(git -C "$REPO_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
applied_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "Applying Gambit CM5 image layer"
echo "  rootfs:        $ROOTFS"
echo "  bootfs:        $BOOTFS"
echo "  image version: $IMAGE_VERSION"
echo "  scripts ref:   $cm5_ref"

# Boot and system configuration.
install_file 0644 "$REPO_DIR/config/config.txt" "$BOOTFS/config.txt"
install_file 0644 "$REPO_DIR/config/asound.conf" "$ROOTFS/etc/asound.conf"
install_file 0644 "$REPO_DIR/config/logind-power-button.conf" \
    "$ROOTFS/etc/systemd/logind.conf.d/50-gambit-power-button.conf"

if [[ -f "$BOOTFS/cmdline.txt" ]]; then
    cmdline="$(tr -d '\n' < "$BOOTFS/cmdline.txt")"

    add_cmdline_token() {
        local token="$1"
        if [[ " $cmdline " != *" $token "* ]]; then
            cmdline="$cmdline $token"
        fi
    }

    set_cmdline_key() {
        local key="$1"
        local value="$2"
        local next=""
        local token
        for token in $cmdline; do
            if [[ "$token" == "$key="* ]]; then
                continue
            fi
            next="${next:+$next }$token"
        done
        cmdline="$next $key=$value"
    }

    add_cmdline_token "quiet"
    add_cmdline_token "splash"
    add_cmdline_token "logo.nologo"
    add_cmdline_token "plymouth.ignore-serial-consoles"
    set_cmdline_key "loglevel" "0"
    set_cmdline_key "vt.global_cursor_default" "0"
    set_cmdline_key "systemd.show_status" "false"
    set_cmdline_key "rd.systemd.show_status" "false"
    set_cmdline_key "udev.log_level" "3"

    printf '%s\n' "$cmdline" > "$BOOTFS/cmdline.txt"
else
    echo "Warning: missing $BOOTFS/cmdline.txt; boot console may show kernel text" >&2
fi

write_file 0644 "$ROOTFS/etc/modules-load.d/gambit-i2c.conf" <<'EOF'
# Expose /dev/i2c-* adapters for Viam modules and local button/sensor tooling.
i2c-dev
EOF
write_file 0644 "$ROOTFS/etc/udev/rules.d/90-gambit-touchscreen-calibration.rules" <<'EOF'
# The DSI panel is mounted/displayed 180 degrees from the kernel touch frame.
# Keep touchscreen coordinates aligned with the rotated Wayland output.
ACTION=="add|change", KERNEL=="event*", ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="-1 0 1 0 -1 1"
EOF
mask_system_unit userconfig.service
mask_system_unit dev-dri-renderD128.device

# Raspberry Pi's chromium package may install a Google API key env file. The
# Gambit image should not bake third-party API keys, even package defaults.
rm -f "$ROOTFS/etc/chromium.d/apikeys"

# Runtime directories. /run is tmpfs and created on boot.
write_file 0644 "$ROOTFS/etc/tmpfiles.d/gambit-runtime.conf" <<'EOF'
# Gambit runtime tmpfs directory. Holds /run/gambit/cook-active and
# /run/gambit/session-active presence files.
d /run/gambit 0755 root root -
EOF
install -d -m 0755 "$ROOTFS/var/lib/gambit/bootstrap"
install -d -m 0755 "$ROOTFS/var/lib/gambit/chef"
install -d -m 0700 "$ROOTFS/etc/gambit/identity"

# Audio boot chime.
install_file 0644 "$REPO_DIR/audio/boot-chime.wav" \
    "$ROOTFS/usr/local/share/gambit/boot-chime.wav"
write_file 0644 "$ROOTFS/etc/systemd/system/gambit-boot-chime.service" <<'EOF'
[Unit]
Description=Gambit boot chime
DefaultDependencies=no
After=local-fs.target sound.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for i in $(seq 1 20); do /usr/bin/aplay -q /usr/local/share/gambit/boot-chime.wav && exit 0; sleep 0.25; done; exit 0'
TimeoutStartSec=8

[Install]
WantedBy=sysinit.target
EOF
install -d -m 0755 "$ROOTFS/etc/systemd/system/sysinit.target.wants"
ln -sfn "../gambit-boot-chime.service" "$ROOTFS/etc/systemd/system/sysinit.target.wants/gambit-boot-chime.service"

# Low-power system unit and runtime scripts.
write_file 0644 "$ROOTFS/etc/systemd/system/gambit-cpu-governor.service" <<'EOF'
[Unit]
Description=Gambit: pin CPU governor to schedutil for power efficiency
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do echo schedutil > "$c" || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
enable_system_unit gambit-cpu-governor.service

# One-time post-provision viam-agent activation. The factory image ships an
# older viam-agent; once the freshly-claimed device downloads its target
# version, viam-agent only activates it on its own update window. This nudges
# activation so setup ends on a current agent (and the matching viam-server).
# A newer binary in the cache means the agent's target already advanced past
# the running version, so a restart swaps it in. Self-bounded and one-shot.
write_file 0755 "$ROOTFS/usr/local/bin/gambit-agent-activate" <<'EOF'
#!/bin/sh
set -eu

MARKER=/var/lib/gambit/agent-activate.done
CACHE=/opt/viam/cache
DEADLINE=$(( $(date +%s) + 600 ))

agent_version() {
    /opt/viam/bin/viam-agent --version 2>/dev/null \
        | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

newest_cached() {
    ls -1 "$CACHE"/viam-agent-v*-* 2>/dev/null \
        | sed -n 's#.*/viam-agent-v\([0-9][0-9.]*\)-.*#\1#p' \
        | sort -V | tail -1
}

# is_newer A B -> A > B
is_newer() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ] && [ "$1" != "$2" ]
}

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    running="$(agent_version)"
    newest="$(newest_cached)"
    if [ -n "$running" ] && [ -n "$newest" ] && is_newer "$newest" "$running"; then
        logger -t gambit-agent-activate "activating viam-agent $newest (was $running)"
        systemctl restart viam-agent || true
        break
    fi
    sleep 30
done

install -d -m 0755 /var/lib/gambit
date -u +%Y-%m-%dT%H:%M:%SZ > "$MARKER"
EOF
write_file 0644 "$ROOTFS/etc/systemd/system/gambit-agent-activate.service" <<'EOF'
[Unit]
Description=Gambit: activate newest downloaded viam-agent (one-time, post-provision)
After=viam-agent.service network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/gambit/agent-activate.done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gambit-agent-activate
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
EOF
enable_system_unit gambit-agent-activate.service

install_file 0755 "$REPO_DIR/lowpower/dim.sh" "$ROOTFS/usr/local/bin/gambit-dim"
install_file 0755 "$REPO_DIR/lowpower/gambit-input-idle.sh" \
    "$ROOTFS/usr/local/bin/gambit-input-idle"
install_file 0644 "$REPO_DIR/lowpower/idle-dim.service.template" \
    "$ROOTFS/usr/local/share/gambit/systemd/user/gambit-idle-dim.service.template"
write_file 0644 "$ROOTFS/etc/systemd/system/gambit-default-brightness.service" <<'EOF'
[Unit]
Description=Gambit: set default display brightness
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'brightnessctl --quiet set 25%% || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
enable_system_unit gambit-default-brightness.service

cursor_theme_dir="$ROOTFS/usr/share/icons/invisible-cursor/cursors"
install -d -m 0755 "$cursor_theme_dir"
write_file 0644 "$ROOTFS/usr/share/icons/invisible-cursor/index.theme" <<'EOF'
[Icon Theme]
Name=invisible-cursor
Comment=Transparent cursor for kiosk
EOF

# Minimal Xcursor file: 1x1 fully transparent image.
printf '\x58\x63\x75\x72' > "$cursor_theme_dir/left_ptr"
printf '\x10\x00\x00\x00' >> "$cursor_theme_dir/left_ptr"
printf '\x00\x00\x01\x00' >> "$cursor_theme_dir/left_ptr"
printf '\x01\x00\x00\x00' >> "$cursor_theme_dir/left_ptr"
printf '\x02\x00\xfd\xff' >> "$cursor_theme_dir/left_ptr"
printf '\x01\x00\x00\x00' >> "$cursor_theme_dir/left_ptr"
printf '\x1c\x00\x00\x00' >> "$cursor_theme_dir/left_ptr"
printf '\x24\x00\x00\x00' >> "$cursor_theme_dir/left_ptr"
printf '\x02\x00\xfd\xff' >> "$cursor_theme_dir/left_ptr"
printf '\x01\x00\x00\x00' >> "$cursor_theme_dir/left_ptr"
printf '\x01\x00\x00\x00' >> "$cursor_theme_dir/left_ptr"
printf '\x01\x00\x00\x00' >> "$cursor_theme_dir/left_ptr"
printf '\x01\x00\x00\x00' >> "$cursor_theme_dir/left_ptr"
printf '\x00\x00\x00\x00' >> "$cursor_theme_dir/left_ptr"
printf '\x00\x00\x00\x00' >> "$cursor_theme_dir/left_ptr"
printf '\x00\x00\x00\x00' >> "$cursor_theme_dir/left_ptr"
printf '\x00\x00\x00\x00' >> "$cursor_theme_dir/left_ptr"
chmod 0644 "$cursor_theme_dir/left_ptr"
for name in default pointer hand1 hand2 text xterm ibeam vertical-text \
    crosshair move watch wait progress top_left_arrow left_ptr_watch grab \
    grabbing n-resize s-resize e-resize w-resize ne-resize nw-resize \
    se-resize sw-resize ew-resize ns-resize nesw-resize nwse-resize \
    col-resize row-resize sb_h_double_arrow sb_v_double_arrow all-scroll \
    not-allowed no-drop copy alias context-menu help cell zoom-in zoom-out \
    dnd-none dnd-move dnd-copy dnd-link crossed_circle none; do
    [[ "$name" != "left_ptr" ]] && ln -sfn left_ptr "$cursor_theme_dir/$name"
done

# Local kiosk session. The image deliberately creates no login password; LightDM
# autologin owns the physical touchscreen session.
write_file 0644 "$ROOTFS/usr/local/share/gambit/kiosk-splash/index.html" <<'EOF'
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
EOF

write_file 0755 "$ROOTFS/usr/local/bin/gambit-kiosk-splash-server" <<'EOF'
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
EOF

write_file 0755 "$ROOTFS/usr/local/bin/gambit-ble-diag" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

section() {
    printf '\n== %s ==\n' "$1"
}

run() {
    printf '$ %s\n' "$*"
    "$@" 2>&1 || true
}

section "time"
run date --iso-8601=seconds
run uptime

section "provisioning files"
if [[ -e /etc/viam.json ]]; then
    echo "/etc/viam.json: present; setup advertising may already be complete"
else
    echo "/etc/viam.json: missing; setup advertising should be active"
fi
run ls -l /etc/viam.json /etc/viam-defaults.json
if [[ -r /etc/viam-defaults.json ]]; then
    grep -E '"manufacturer"|"model"|"hotspot_prefix"|"hotspot_interface"|"fragment_id"' /etc/viam-defaults.json || true
fi

section "services"
run systemctl is-active bluetooth.service
run systemctl is-active viam-agent.service
run systemctl status bluetooth.service --no-pager -l
run systemctl status viam-agent.service --no-pager -l

section "bluetooth controller"
run rfkill list bluetooth
run bluetoothctl show
if command -v btmgmt >/dev/null 2>&1; then
    run btmgmt info
    run btmgmt advinfo
fi
if command -v hciconfig >/dev/null 2>&1; then
    run hciconfig -a
fi

section "recent bluetooth logs"
journalctl -u bluetooth.service -b --no-pager -n 160 2>&1 || true

section "recent viam-agent ble/provisioning logs"
journalctl -u viam-agent.service -b --no-pager -n 500 2>&1 \
    | grep -iE 'ble|bluetooth|advertis|gatt|provision|setup|viam.json|viam-defaults|error|failed|panic|rfkill' \
    || true

cat <<'DIAG'

Interpretation:
- If bluetooth.service is inactive, rfkill is blocked, or bluetoothctl show lacks Powered: yes, this is the Pi Bluetooth stack.
- If Bluetooth is powered but /etc/viam.json is missing and viam-agent logs do not show setup advertising, this is the viam-agent provisioning advertiser path.
- If advertising is present in logs but the app cannot see it, compare with a generic BLE scanner to separate app scan behavior from device advertising.
- If /etc/viam.json is present, the device may be past BLE setup and no longer expected to advertise setup.
DIAG
EOF

write_file 0755 "$ROOTFS/usr/local/bin/gambit-start-kiosk" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

KIOSK_URL="${KIOSK_URL:-http://127.0.0.1:8765/kiosk/help}"
SPLASH_PORT="${SPLASH_PORT:-8764}"
SPLASH_DIR="${SPLASH_DIR:-/usr/local/share/gambit/kiosk-splash}"
READY_LOG_INTERVAL="${READY_LOG_INTERVAL:-30}"
WEB_CHECK_INTERVAL="${WEB_CHECK_INTERVAL:-5}"
WEB_FAILURE_LIMIT="${WEB_FAILURE_LIMIT:-3}"
RESTART_REQUESTED="/tmp/gambit-kiosk-restart-requested.$$"
rm -f "$RESTART_REQUESTED"

echo "Waiting for Wayland display..."
for _ in $(seq 1 180); do
    if [[ -n "${XDG_RUNTIME_DIR:-}" && -n "${WAYLAND_DISPLAY:-}" && -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
        break
    fi
    sleep 1
done

if [[ -z "${XDG_RUNTIME_DIR:-}" || -z "${WAYLAND_DISPLAY:-}" || ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
    echo "Error: Wayland display never appeared. Exiting."
    exit 1
fi

pkill -u "$(whoami)" -f "chromium.*user-data-dir=/tmp/chromium-kiosk" 2>/dev/null || true
pkill -u "$(whoami)" -f "python3 -m http.server $SPLASH_PORT" 2>/dev/null || true
pkill -u "$(whoami)" -f "gambit-kiosk-splash-server.*--port $SPLASH_PORT" 2>/dev/null || true

SPLASH_DIR="$SPLASH_DIR" KIOSK_URL="$KIOSK_URL" gambit-kiosk-splash-server --port "$SPLASH_PORT" >/tmp/gambit-kiosk-splash.log 2>&1 &
SPLASH_PID=$!
trap 'kill "$SPLASH_PID" 2>/dev/null || true; rm -f "$RESTART_REQUESTED"' EXIT

encoded_target="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$KIOSK_URL")"
SPLASH_URL="http://127.0.0.1:${SPLASH_PORT}/?target=${encoded_target}"

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

set +e
wait "$CHROMIUM_PID"
chromium_status=$?
set -e
if [[ -f "$RESTART_REQUESTED" ]]; then
    echo "Exiting nonzero so systemd restarts kiosk at splash."
    exit 1
fi
exit "$chromium_status"
EOF

write_file 0644 "$ROOTFS/usr/local/share/gambit/systemd/user/kiosk.service" <<'EOF'
[Unit]
Description=Chef Display Kiosk (Wayland)
After=graphical-session.target

[Service]
Environment=WAYLAND_DISPLAY=wayland-0
Environment=XCURSOR_THEME=invisible-cursor
Environment=XCURSOR_SIZE=1
ExecStart=/usr/local/bin/gambit-start-kiosk
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

write_file 0644 "$ROOTFS/usr/share/wayland-sessions/gambit-labwc.desktop" <<'EOF'
[Desktop Entry]
Name=Gambit Labwc
Comment=Gambit kiosk Wayland session
Exec=labwc
Type=Application
DesktopNames=labwc
EOF

write_file 0644 "$ROOTFS/etc/xdg/labwc/autostart" <<'EOF'
swaybg -c '#1a1d23' &
/usr/bin/kanshi &
/bin/sh -c 'sleep 2; wlr-randr --output DSI-2 --transform 180' &
EOF

write_file 0755 "$ROOTFS/usr/local/sbin/gambit-setup-local-kiosk-user" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

KIOSK_USER="${GAMBIT_KIOSK_USER:-gambitadmin}"
MARKER="/var/lib/gambit/bootstrap/kiosk-local-user.done"

if [[ -f "$MARKER" ]]; then
    exit 0
fi

existing_groups=()
for group in adm dialout cdrom sudo audio video plugdev users input render netdev gpio i2c spi; do
    if getent group "$group" >/dev/null; then
        existing_groups+=("$group")
    fi
done

if ! id "$KIOSK_USER" >/dev/null 2>&1; then
    args=(-m -s /bin/bash)
    if (( ${#existing_groups[@]} > 0 )); then
        IFS=,
        args+=(-G "${existing_groups[*]}")
        unset IFS
    fi
    useradd "${args[@]}" "$KIOSK_USER"
else
    for group in "${existing_groups[@]}"; do
        usermod -aG "$group" "$KIOSK_USER" || true
    done
fi

# Keep the image free of baked login secrets. Autologin owns the kiosk session.
passwd -l "$KIOSK_USER" >/dev/null 2>&1 || true

user_home="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"
user_id="$(id -u "$KIOSK_USER")"

install -d -o "$KIOSK_USER" -g "$KIOSK_USER" "$user_home/.config/systemd/user/default.target.wants"
install -d -o "$KIOSK_USER" -g "$KIOSK_USER" "$user_home/.config/labwc"
install -m 0644 -o "$KIOSK_USER" -g "$KIOSK_USER" \
    /usr/local/share/gambit/systemd/user/kiosk.service \
    "$user_home/.config/systemd/user/kiosk.service"
ln -sfn ../kiosk.service "$user_home/.config/systemd/user/default.target.wants/kiosk.service"
chown -h "$KIOSK_USER:$KIOSK_USER" "$user_home/.config/systemd/user/default.target.wants/kiosk.service"

cat > "$user_home/.config/labwc/environment" <<'LABWC_ENV'
XCURSOR_THEME=invisible-cursor
XCURSOR_SIZE=1
LABWC_ENV
chown "$KIOSK_USER:$KIOSK_USER" "$user_home/.config/labwc/environment"

install -d -m 0755 /var/lib/systemd/linger
touch "/var/lib/systemd/linger/$KIOSK_USER"

install -d -m 0755 /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/12-gambit-autologin.conf <<LIGHTDM
[Seat:*]
autologin-user=$KIOSK_USER
autologin-user-timeout=0
user-session=gambit-labwc
LIGHTDM

if [[ -f /etc/xdg/labwc/autostart ]] && [[ ! -f /etc/xdg/labwc/autostart.bak ]]; then
    cp /etc/xdg/labwc/autostart /etc/xdg/labwc/autostart.bak
fi
install -d -m 0755 /etc/xdg/labwc
cat > /etc/xdg/labwc/autostart <<'AUTOSTART'
swaybg -c '#1a1d23' &
/usr/bin/kanshi &
/bin/sh -c 'sleep 2; wlr-randr --output DSI-2 --transform 180' &
AUTOSTART

systemctl disable userconfig.service >/dev/null 2>&1 || true
systemctl mask userconfig.service >/dev/null 2>&1 || true
systemctl mask dev-dri-renderD128.device >/dev/null 2>&1 || true

install -d -m 0755 "$(dirname "$MARKER")"
printf 'configured_at=%s\nuser=%s\nsession=%s\nuid=%s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$KIOSK_USER" "gambit-labwc" "$user_id" > "$MARKER"
EOF

write_file 0644 "$ROOTFS/etc/systemd/system/gambit-kiosk-local-user.service" <<'EOF'
[Unit]
Description=Gambit first-boot local kiosk user setup
DefaultDependencies=no
After=local-fs.target
Before=display-manager.service lightdm.service
ConditionPathExists=!/var/lib/gambit/bootstrap/kiosk-local-user.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gambit-setup-local-kiosk-user

[Install]
WantedBy=multi-user.target
EOF
enable_system_unit gambit-kiosk-local-user.service

write_file 0755 "$ROOTFS/usr/local/sbin/gambit-kiosk-recovery" <<'EOF'
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
EOF

write_file 0644 "$ROOTFS/etc/systemd/system/gambit-kiosk-recovery.service" <<EOF
[Unit]
Description=Gambit kiosk display recovery watchdog
After=lightdm.service
Wants=lightdm.service

[Service]
Type=simple
Environment=GAMBIT_KIOSK_USER=$TARGET_USER
ExecStart=/usr/local/sbin/gambit-kiosk-recovery
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
enable_system_unit gambit-kiosk-recovery.service

write_file 0755 "$ROOTFS/usr/local/bin/gambit-button-controller" <<'EOF'
#!/usr/bin/env python3
import os
import signal
import subprocess
import sys
import time

try:
    import smbus2
except ImportError:
    import smbus as smbus2

I2C_ADDR = int(os.environ.get("BUTTON_I2C_ADDR", "0x3E"), 16)
VOLUME_STEP = int(os.environ.get("VOLUME_STEP", "5"))
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "0.05"))
ALSA_MIXER = os.environ.get("ALSA_MIXER", "Speaker")

running = True

def shutdown(_signum, _frame):
    global running
    running = False

def volume(delta):
    suffix = "+" if delta > 0 else "-"
    subprocess.run(["amixer", "sset", ALSA_MIXER, f"{VOLUME_STEP}%{suffix}"], check=False)

signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)

bus = smbus2.SMBus(1)
states = [False, False, False]
pressed_at = [0.0, 0.0, 0.0]
last_repeat = [0.0, 0.0, 0.0]
actions = [1, None, -1]

while running:
    now = time.time()
    try:
        data = bus.read_i2c_block_data(I2C_ADDR, 0, 4)
        buttons = [bool(data[1]), bool(data[2]), bool(data[3])]
    except OSError as exc:
        print(f"I2C read failed: {exc}", file=sys.stderr)
        time.sleep(1)
        continue

    leds = [0, 0, 0]
    for i, pressed in enumerate(buttons):
        action = actions[i]
        if action is None:
            states[i] = pressed
            continue
        if pressed and not states[i]:
            pressed_at[i] = now
            last_repeat[i] = now
            volume(action)
        elif pressed and states[i] and now - pressed_at[i] > 0.4 and now - last_repeat[i] >= 0.2:
            last_repeat[i] = now
            volume(action)
        leds[i] = 1 if pressed else 0
        states[i] = pressed

    try:
        bus.write_i2c_block_data(I2C_ADDR, 0, leds)
    except OSError as exc:
        print(f"I2C LED write failed: {exc}", file=sys.stderr)
    time.sleep(POLL_INTERVAL)

try:
    bus.write_i2c_block_data(I2C_ADDR, 0, [0, 0, 0])
except OSError:
    pass
EOF

write_file 0644 "$ROOTFS/usr/local/share/gambit/systemd/user/buttons.service" <<'EOF'
[Unit]
Description=I2C Button Controller (Volume)
After=multi-user.target

[Service]
Environment=BUTTON_I2C_ADDR=0x3E
Environment=VOLUME_STEP=5
Environment=POLL_INTERVAL=0.05
Environment=ALSA_MIXER=Speaker
ExecStart=/usr/bin/python3 /usr/local/bin/gambit-button-controller
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

# Plymouth theme files. The outer builder should run plymouth-set-default-theme
# and update-initramfs inside the image/chroot after packages are installed.
plymouth_dir="$ROOTFS/usr/share/plymouth/themes/gambit"
install -d -m 0755 "$plymouth_dir"
install_file 0644 "$REPO_DIR/plymouth/SplashLoading.png" "$plymouth_dir/splash.png"
install_file 0644 "$REPO_DIR/plymouth/SplashShutdown.png" "$plymouth_dir/shutdown-splash.png"
install_file 0644 "$REPO_DIR/plymouth/dot.png" "$plymouth_dir/dot.png"
write_file 0644 "$ROOTFS/etc/plymouth/plymouthd.conf" <<'EOF'
[Daemon]
Theme=gambit
ShowDelay=0
DeviceTimeout=8
EOF
write_file 0644 "$plymouth_dir/gambit.plymouth" <<'EOF'
[Plymouth Theme]
Name=gambit
Description=Gambit boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/gambit
ScriptFile=/usr/share/plymouth/themes/gambit/gambit.script
EOF
awk '/^# Plymouth theme script/{flag=1} flag{print}' "$REPO_DIR/plymouth/setup-bootsplash.sh" \
    | sed '/^EOF$/,$d' > "$plymouth_dir/gambit.script"
chmod 0644 "$plymouth_dir/gambit.script"

install_file 0644 "$VIAM_DEFAULTS" "$ROOTFS/etc/viam-defaults.json"

write_file 0644 "$ROOTFS/etc/gambit/image-build.json" <<EOF
{
  "image_version": "$IMAGE_VERSION",
  "cm5_local_scripts_ref": "$cm5_ref",
  "applied_at": "$applied_at",
  "target_user_hint": "$TARGET_USER"
}
EOF

"$SCRIPT_DIR/verify-rootfs.sh" --rootfs "$ROOTFS" --bootfs "$BOOTFS"

echo "Gambit CM5 image layer applied."
