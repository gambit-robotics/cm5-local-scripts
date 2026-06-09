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

# Local kiosk session. The image deliberately creates no login password; LightDM
# autologin owns the physical touchscreen session.
write_file 0755 "$ROOTFS/usr/local/bin/gambit-start-kiosk" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

KIOSK_URL="${KIOSK_URL:-http://127.0.0.1:8765/kiosk/help}"
READY_LOG_INTERVAL="${READY_LOG_INTERVAL:-30}"

echo "Waiting for Wayland display..."
for _ in $(seq 1 180); do
    if [[ -n "${XDG_RUNTIME_DIR:-}" && -n "${WAYLAND_DISPLAY:-}" && -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
        break
    fi
    sleep 1
done

waited=0
while ! curl -fsS "$KIOSK_URL" >/dev/null 2>&1; do
    sleep 2
    waited=$((waited + 2))
    if (( waited % READY_LOG_INTERVAL == 0 )); then
        echo "Still waiting for web server at $KIOSK_URL (${waited}s)"
    fi
done
echo "Web server ready after ${waited}s."

pkill -u "$(whoami)" -f "chromium.*user-data-dir=/tmp/chromium-kiosk" 2>/dev/null || true

exec chromium \
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
    "$KIOSK_URL"
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

session="gambit-labwc"
if [[ ! -f /usr/share/wayland-sessions/gambit-labwc.desktop && -d /usr/share/wayland-sessions ]]; then
    while IFS= read -r candidate; do
        session="$(basename "$candidate" .desktop)"
        break
    done < <(find /usr/share/wayland-sessions -maxdepth 1 -type f -iname '*labwc*.desktop' | sort)
fi

install -d -m 0755 /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/12-gambit-autologin.conf <<LIGHTDM
[Seat:*]
autologin-user=$KIOSK_USER
autologin-user-timeout=0
user-session=$session
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
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$KIOSK_USER" "$session" "$user_id" > "$MARKER"
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
