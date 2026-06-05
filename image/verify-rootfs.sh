#!/usr/bin/env bash
set -euo pipefail

ROOTFS=""

usage() {
    cat <<'EOF'
Usage: image/verify-rootfs.sh --rootfs PATH

Checks a mounted rootfs for the no-secrets and BLE provisioning image contract.
EOF
}

die() { echo "Error: $*" >&2; exit 1; }
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootfs) ROOTFS="${2:-}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$ROOTFS" ]] || die "--rootfs is required"
[[ -d "$ROOTFS" ]] || die "rootfs does not exist: $ROOTFS"

failures=0

if [[ -f "$ROOTFS/etc/shadow" ]]; then
while IFS=: read -r user hash _rest; do
        [[ -z "$user" ]] && continue
        if [[ "$hash" =~ ^\$[A-Za-z0-9] ]]; then
            fail "login password hash is baked for user '$user'"
        fi
    done < "$ROOTFS/etc/shadow"
fi

while IFS= read -r path; do
    fail "authorized_keys is baked: ${path#$ROOTFS/}"
done < <(find "$ROOTFS" -path '*/.ssh/authorized_keys' -type f 2>/dev/null || true)

while IFS= read -r path; do
    fail "SSH host private key is baked: ${path#$ROOTFS/}"
done < <(find "$ROOTFS/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*_key' 2>/dev/null || true)

if [[ -f "$ROOTFS/etc/viam.json" ]]; then
    fail "per-device /etc/viam.json is baked into the image"
fi

if ! find "$ROOTFS/usr/include" -maxdepth 2 -type f -name Python.h 2>/dev/null | grep -q .; then
    fail "missing Python.h; install python3-dev so Viam Python modules can build native wheels"
fi

if [[ ! -f "$ROOTFS/etc/modules-load.d/gambit-i2c.conf" ]] || ! grep -Eq '^[[:space:]]*i2c-dev([[:space:]]*#.*)?$' "$ROOTFS/etc/modules-load.d/gambit-i2c.conf"; then
    fail "missing i2c-dev modules-load config for /dev/i2c-* adapters"
fi

kiosk_splash="$ROOTFS/usr/local/share/gambit/kiosk-splash/index.html"
if [[ ! -f "$kiosk_splash" ]] || ! grep -Eq 'Starting Gambit' "$kiosk_splash"; then
    fail "missing local kiosk startup splash page"
fi

kiosk_launcher="$ROOTFS/usr/local/bin/gambit-start-kiosk"
if [[ ! -x "$kiosk_launcher" ]]; then
    fail "missing executable kiosk launcher"
else
    if ! grep -Eq 'python3 -m http\.server "\$SPLASH_PORT"' "$kiosk_launcher"; then
        fail "kiosk launcher does not start local splash server"
    fi
    if ! grep -Eq 'SPLASH_URL=' "$kiosk_launcher"; then
        fail "kiosk launcher does not open splash before local app is ready"
    fi
    if ! grep -Eq 'WEB_FAILURE_LIMIT' "$kiosk_launcher"; then
        fail "kiosk launcher does not monitor local app health after startup"
    fi
fi

dim_script="$ROOTFS/usr/local/bin/gambit-dim"
if [[ ! -x "$dim_script" ]] || ! grep -Fq 'FULL_LEVEL="${FULL_LEVEL:-25%}"' "$dim_script"; then
    fail "missing normal screen brightness default of 25%"
fi

default_brightness_service="$ROOTFS/etc/systemd/system/gambit-default-brightness.service"
if [[ ! -f "$default_brightness_service" ]] || ! grep -Fq 'brightnessctl --quiet set 25%%' "$default_brightness_service"; then
    fail "missing default brightness service at 25%"
fi

if [[ ! -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/gambit-default-brightness.service" ]]; then
    fail "gambit-default-brightness.service is not enabled"
fi

cursor_theme="$ROOTFS/usr/share/icons/invisible-cursor/cursors/left_ptr"
if [[ ! -f "$cursor_theme" ]] || [[ "$(wc -c < "$cursor_theme" | tr -d ' ')" != "68" ]]; then
    fail "missing baked invisible cursor theme"
fi

kiosk_service_template="$ROOTFS/usr/local/share/gambit/systemd/user/kiosk.service"
if [[ ! -f "$kiosk_service_template" ]] || ! grep -Fq 'Environment=XCURSOR_THEME=invisible-cursor' "$kiosk_service_template"; then
    fail "kiosk service does not set invisible cursor theme"
fi

kiosk_setup="$ROOTFS/usr/local/sbin/gambit-setup-local-kiosk-user"
if [[ ! -x "$kiosk_setup" ]]; then
    fail "missing executable local kiosk user setup script"
else
    if ! grep -Eq 'GAMBIT_KIOSK_USER:-gambitadmin' "$kiosk_setup"; then
        fail "local kiosk setup does not default to gambitadmin"
    fi
    if ! grep -Eq 'user-session=gambit-labwc' "$kiosk_setup"; then
        fail "local kiosk setup does not configure gambit-labwc autologin"
    fi
    if ! grep -Eq 'mask userconfig\.service' "$kiosk_setup"; then
        fail "local kiosk setup does not mask Raspberry Pi first-user service"
    fi
fi

if [[ ! -L "$ROOTFS/etc/systemd/system/userconfig.service" ]] || [[ "$(readlink "$ROOTFS/etc/systemd/system/userconfig.service")" != "/dev/null" ]]; then
    fail "userconfig.service is not masked; first-user wizard can block kiosk boot"
fi

if [[ ! -L "$ROOTFS/etc/systemd/system/dev-dri-renderD128.device" ]] || [[ "$(readlink "$ROOTFS/etc/systemd/system/dev-dri-renderD128.device")" != "/dev/null" ]]; then
    fail "dev-dri-renderD128.device is not masked; LightDM can wait for a missing render node"
fi

if [[ ! -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/gambit-kiosk-local-user.service" ]]; then
    fail "gambit-kiosk-local-user.service is not enabled"
fi

wayland_session="$ROOTFS/usr/share/wayland-sessions/gambit-labwc.desktop"
if [[ ! -f "$wayland_session" ]] || ! grep -Eq '^Exec=labwc$' "$wayland_session"; then
    fail "missing gambit-labwc Wayland session"
fi

labwc_autostart="$ROOTFS/etc/xdg/labwc/autostart"
if [[ ! -f "$labwc_autostart" ]] || ! grep -Eq 'wlr-randr --output DSI-2 --transform 180' "$labwc_autostart"; then
    fail "missing DSI-2 180-degree kiosk display transform"
fi

viam_defaults="$ROOTFS/etc/viam-defaults.json"
if [[ ! -f "$viam_defaults" ]]; then
    fail "missing /etc/viam-defaults.json for BLE provisioning"
else
    if grep -Eq '"secret"[[:space:]]*:[[:space:]]*"[^"]+"' "$viam_defaults"; then
        fail "etc/viam-defaults.json contains a cloud secret"
    fi
    if ! grep -Eq '"manufacturer"[[:space:]]*:[[:space:]]*"Gambit Robotics"' "$viam_defaults"; then
        fail "etc/viam-defaults.json missing manufacturer=Gambit Robotics"
    fi
    if ! grep -Eq '"model"[[:space:]]*:[[:space:]]*"CM5"' "$viam_defaults"; then
        fail "etc/viam-defaults.json missing model=CM5"
    fi
    if ! grep -Eq '"fragment_id"[[:space:]]*:[[:space:]]*"f55bd1ed-142c-4232-9ac1-18eba4f99c87"' "$viam_defaults"; then
        fail "etc/viam-defaults.json missing User Testing fragment_id"
    fi
    if ! grep -Eq '"hotspot_interface"[[:space:]]*:[[:space:]]*"wlan0"' "$viam_defaults"; then
        fail "etc/viam-defaults.json missing hotspot_interface=wlan0"
    fi
    if ! grep -Eq '"hotspot_prefix"[[:space:]]*:[[:space:]]*"gambit-setup"' "$viam_defaults"; then
        fail "etc/viam-defaults.json missing hotspot_prefix=gambit-setup"
    fi
    if ! grep -Eq '"hotspot_password"[[:space:]]*:[[:space:]]*"gambitsetup"' "$viam_defaults"; then
        fail "etc/viam-defaults.json missing hotspot_password expected by the app"
    fi
fi

if [[ -d "$ROOTFS/etc/gambit/identity" ]]; then
    while IFS= read -r path; do
        fail "device identity material is baked: ${path#$ROOTFS/}"
    done < <(find "$ROOTFS/etc/gambit/identity" -type f \( -name '*.key' -o -name '*.crt' -o -name '*.pem' \) 2>/dev/null || true)
fi

while IFS= read -r path; do
    case "${path#$ROOTFS/}" in
        etc/ssl/certs/*|usr/share/ca-certificates/*|usr/local/share/ca-certificates/*)
            continue
            ;;
    esac
    if grep -Iq . "$path" && grep -Eq 'BEGIN PRIVATE KEY|BEGIN RSA PRIVATE KEY|BEGIN EC PRIVATE KEY|BEGIN OPENSSH PRIVATE KEY|PRIVATE KEY-----' "$path"; then
        fail "private key PEM content is baked: ${path#$ROOTFS/}"
    fi
done < <(find "$ROOTFS/etc" "$ROOTFS/usr/local" "$ROOTFS/var/lib/gambit" -type f 2>/dev/null || true)

while IFS= read -r path; do
    fail "cm5-local-scripts repo material is baked: ${path#$ROOTFS/}"
done < <(find "$ROOTFS" \( -name '.git' -o -name 'install.sh' -o -name 'uninstall.sh' -o -name 'Makefile' \) 2>/dev/null | grep -E 'cm5-local-scripts|/opt/gambit/source|/home/.*/cm5-local-scripts' || true)

secret_pattern='((^|[^[:alnum:]])(api[_-]?key|apikey)([^[:alnum:]]|$)|cloudflare[_-]?api|atlas|mongodb://|mongodb[+]srv://|elevenlabs|anthropic|openai|gemini|sk-[A-Za-z0-9_-]{20,}|password:[[:space:]]*[^[:space:]]+)'
while IFS= read -r path; do
    case "${path#$ROOTFS/}" in
        etc/gambit/image-build.json)
            continue
            ;;
    esac
    if grep -Iq . "$path" && grep -Eiq "$secret_pattern" "$path"; then
        fail "possible secret-bearing text in ${path#$ROOTFS/}"
    fi
done < <(find "$ROOTFS/etc" "$ROOTFS/usr/local" "$ROOTFS/var/lib/gambit" -type f -size -512k 2>/dev/null || true)

if [[ "$failures" -gt 0 ]]; then
    echo "Rootfs verification failed with $failures issue(s)." >&2
    exit 1
fi

echo "Rootfs verification passed."
