#!/usr/bin/env bash
set -euo pipefail

ROOTFS=""
BOOTFS=""

usage() {
    cat <<'EOF'
Usage: image/verify-rootfs.sh --rootfs PATH [--bootfs PATH]

Checks a mounted rootfs for the no-secrets and BLE provisioning image contract.
EOF
}

die() { echo "Error: $*" >&2; exit 1; }
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootfs) ROOTFS="${2:-}"; shift 2 ;;
        --bootfs) BOOTFS="${2:-}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$ROOTFS" ]] || die "--rootfs is required"
[[ -d "$ROOTFS" ]] || die "rootfs does not exist: $ROOTFS"
if [[ -n "$BOOTFS" && ! -d "$BOOTFS" ]]; then
    die "bootfs does not exist: $BOOTFS"
fi

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

boot_chime_service="$ROOTFS/etc/systemd/system/gambit-boot-chime.service"
if [[ ! -f "$boot_chime_service" ]] || ! grep -Fq 'WantedBy=sysinit.target' "$boot_chime_service"; then
    fail "boot chime is not scheduled for early sysinit startup"
fi
if [[ ! -L "$ROOTFS/etc/systemd/system/sysinit.target.wants/gambit-boot-chime.service" ]]; then
    fail "gambit-boot-chime.service is not enabled for sysinit.target"
fi

touchscreen_rule="$ROOTFS/etc/udev/rules.d/90-gambit-touchscreen-calibration.rules"
if [[ ! -f "$touchscreen_rule" ]] || ! grep -Fq 'LIBINPUT_CALIBRATION_MATRIX}="-1 0 1 0 -1 1"' "$touchscreen_rule"; then
    fail "missing 180-degree touchscreen calibration rule"
fi

plymouth_conf="$ROOTFS/etc/plymouth/plymouthd.conf"
if [[ ! -f "$plymouth_conf" ]] || ! grep -Eq '^Theme=gambit$' "$plymouth_conf"; then
    fail "Plymouth default theme is not set to gambit"
fi

kiosk_splash="$ROOTFS/usr/local/share/gambit/kiosk-splash/index.html"
if [[ ! -f "$kiosk_splash" ]] || ! grep -Eq 'Starting Gambit' "$kiosk_splash"; then
    fail "missing local kiosk startup splash page"
fi

splash_server="$ROOTFS/usr/local/bin/gambit-kiosk-splash-server"
if [[ ! -x "$splash_server" ]]; then
    fail "missing executable local kiosk splash state server"
else
    if ! grep -Fq '/state' "$splash_server"; then
        fail "local kiosk splash state server does not expose /state"
    fi
    if ! grep -Fq '/etc/viam.json' "$splash_server"; then
        fail "local kiosk splash state server does not detect BLE provisioning completion"
    fi
    if ! grep -Fq 'journalctl' "$splash_server"; then
        fail "local kiosk splash state server does not inspect viam-agent progress"
    fi
    if ! grep -Fq '["ip", "route", "show", "default"]' "$splash_server"; then
        fail "local kiosk splash state server does not check network readiness before module downloads"
    fi
    if ! grep -Fq 'connect with Bluetooth to finish setup' "$splash_server"; then
        fail "local kiosk splash state server does not explain BLE setup wait"
    fi
    if ! grep -Fq 'Waiting for Wi-Fi' "$splash_server"; then
        fail "local kiosk splash state server does not explain Wi-Fi wait before module downloads"
    fi
    if ! grep -Fq 'Configuring your robot' "$splash_server"; then
        fail "local kiosk splash state server does not explain post-provisioning robot setup"
    fi
fi

ble_diag="$ROOTFS/usr/local/bin/gambit-ble-diag"
if [[ ! -x "$ble_diag" ]]; then
    fail "missing executable BLE provisioning diagnostic"
else
    if ! grep -Fq 'bluetoothctl show' "$ble_diag"; then
        fail "BLE diagnostic does not inspect controller state"
    fi
    if ! grep -Fq 'viam-agent.service' "$ble_diag"; then
        fail "BLE diagnostic does not inspect viam-agent state"
    fi
    if ! grep -Fq '/etc/viam.json' "$ble_diag"; then
        fail "BLE diagnostic does not distinguish provisioned vs setup state"
    fi
    if ! grep -Fq 'journalctl' "$ble_diag"; then
        fail "BLE diagnostic does not capture service logs"
    fi
fi

kiosk_launcher="$ROOTFS/usr/local/bin/gambit-start-kiosk"
if [[ ! -x "$kiosk_launcher" ]]; then
    fail "missing executable kiosk launcher"
else
    if ! grep -Fq 'gambit-kiosk-splash-server --port "$SPLASH_PORT"' "$kiosk_launcher"; then
        fail "kiosk launcher does not start local splash state server"
    fi
    if ! grep -Eq 'SPLASH_URL=' "$kiosk_launcher"; then
        fail "kiosk launcher does not open splash before local app is ready"
    fi
    if ! grep -Eq 'WEB_FAILURE_LIMIT' "$kiosk_launcher"; then
        fail "kiosk launcher does not monitor local app health after startup"
    fi
    if ! grep -Fq 'RESTART_REQUESTED=' "$kiosk_launcher" ||
        ! grep -Fq 'Exiting nonzero so systemd restarts kiosk at splash.' "$kiosk_launcher"; then
        fail "kiosk launcher does not force systemd restart after web health failure"
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
if ! grep -Fq 'Restart=always' "$kiosk_service_template"; then
    fail "kiosk service does not restart after clean browser exit"
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

kiosk_recovery="$ROOTFS/usr/local/sbin/gambit-kiosk-recovery"
if [[ ! -x "$kiosk_recovery" ]]; then
    fail "missing executable kiosk recovery watchdog"
else
    if ! grep -Fq 'lightdm.service' "$kiosk_recovery"; then
        fail "kiosk recovery watchdog does not restart LightDM"
    fi
    if ! grep -Fq 'chromium.*user-data-dir=/tmp/chromium-kiosk' "$kiosk_recovery"; then
        fail "kiosk recovery watchdog does not detect the kiosk browser"
    fi
    if ! grep -Fq 'MISSING_LIMIT' "$kiosk_recovery"; then
        fail "kiosk recovery watchdog does not debounce missing browser recovery"
    fi
fi

kiosk_recovery_service="$ROOTFS/etc/systemd/system/gambit-kiosk-recovery.service"
if [[ ! -f "$kiosk_recovery_service" ]] || ! grep -Fq 'ExecStart=/usr/local/sbin/gambit-kiosk-recovery' "$kiosk_recovery_service"; then
    fail "missing kiosk recovery systemd service"
fi
if [[ ! -L "$ROOTFS/etc/systemd/system/multi-user.target.wants/gambit-kiosk-recovery.service" ]]; then
    fail "gambit-kiosk-recovery.service is not enabled"
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
    if ! grep -Eq '"fragment_id"[[:space:]]*:[[:space:]]*"4af2846b-610d-4ec7-8193-cd195efa0679"' "$viam_defaults"; then
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

if [[ -n "$BOOTFS" ]]; then
    if [[ ! -f "$BOOTFS/config.txt" ]] || ! grep -Eq '^disable_splash=1$' "$BOOTFS/config.txt"; then
        fail "boot config does not hide the firmware splash"
    fi

    if [[ ! -f "$BOOTFS/cmdline.txt" ]]; then
        fail "missing boot cmdline.txt"
    else
        cmdline="$(tr -d '\n' < "$BOOTFS/cmdline.txt")"
        for token in quiet splash logo.nologo plymouth.ignore-serial-consoles loglevel=0 vt.global_cursor_default=0 systemd.show_status=false rd.systemd.show_status=false udev.log_level=3; do
            if [[ " $cmdline " != *" $token "* ]]; then
                fail "boot cmdline missing quiet splash token: $token"
            fi
        done
    fi
fi

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
