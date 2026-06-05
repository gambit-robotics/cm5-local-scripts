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
write_file 0644 "$ROOTFS/etc/modules-load.d/gambit-i2c.conf" <<'EOF'
# Expose /dev/i2c-* adapters for Viam modules and local button/sensor tooling.
i2c-dev
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
After=sound.target

[Service]
Type=oneshot
ExecStart=/usr/bin/aplay -q /usr/local/share/gambit/boot-chime.wav
TimeoutStartSec=10

[Install]
WantedBy=multi-user.target
EOF
enable_system_unit gambit-boot-chime.service

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

python3 -m http.server "$SPLASH_PORT" --bind 127.0.0.1 --directory "$SPLASH_DIR" >/tmp/gambit-kiosk-splash.log 2>&1 &
SPLASH_PID=$!
trap 'kill "$SPLASH_PID" 2>/dev/null || true' EXIT

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
            echo "Kiosk web server unavailable; restarting Chromium at splash."
            kill "$CHROMIUM_PID" 2>/dev/null || true
            exit 0
        fi
    done
) &
WATCHDOG_PID=$!
trap 'kill "$SPLASH_PID" "$WATCHDOG_PID" 2>/dev/null || true' EXIT

wait "$CHROMIUM_PID"
EOF

write_file 0644 "$ROOTFS/usr/local/share/gambit/systemd/user/kiosk.service" <<'EOF'
[Unit]
Description=Chef Display Kiosk (Wayland)
After=graphical-session.target

[Service]
Environment=WAYLAND_DISPLAY=wayland-0
ExecStart=/usr/local/bin/gambit-start-kiosk
Restart=on-failure
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

"$SCRIPT_DIR/verify-rootfs.sh" --rootfs "$ROOTFS"

echo "Gambit CM5 image layer applied."
