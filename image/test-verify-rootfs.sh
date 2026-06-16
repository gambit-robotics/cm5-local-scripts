#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/verify-rootfs.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_rootfs() {
    local dir="$1"
    mkdir -p "$dir/etc/modules-load.d" \
        "$dir/etc/plymouth" \
        "$dir/etc/udev/rules.d" \
        "$dir/etc/systemd/system/sysinit.target.wants" \
        "$dir/etc/systemd/system/multi-user.target.wants" \
        "$dir/etc/xdg/labwc" \
        "$dir/usr/include/python3.13" \
        "$dir/usr/local/bin" \
        "$dir/usr/local/share/gambit/systemd/user" \
        "$dir/usr/local/share/gambit/kiosk-splash" \
        "$dir/usr/share/icons/invisible-cursor/cursors" \
        "$dir/usr/local/sbin" \
        "$dir/usr/share/wayland-sessions" \
        "$dir/var/lib/gambit"
    touch "$dir/usr/include/python3.13/Python.h"
    echo i2c-dev > "$dir/etc/modules-load.d/gambit-i2c.conf"
    cat > "$dir/etc/udev/rules.d/90-gambit-touchscreen-calibration.rules" <<'EOF'
ACTION=="add|change", KERNEL=="event*", ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="-1 0 1 0 -1 1"
EOF
    cat > "$dir/etc/systemd/system/gambit-boot-chime.service" <<'EOF'
[Unit]
Description=Gambit boot chime

[Install]
WantedBy=sysinit.target
EOF
    ln -sfn ../gambit-boot-chime.service "$dir/etc/systemd/system/sysinit.target.wants/gambit-boot-chime.service"
    cat > "$dir/etc/plymouth/plymouthd.conf" <<'EOF'
[Daemon]
Theme=gambit
ShowDelay=0
EOF
    cat > "$dir/usr/local/share/gambit/kiosk-splash/index.html" <<'EOF'
<!doctype html>
<title>Starting Gambit</title>
EOF
    cat > "$dir/usr/local/bin/gambit-start-kiosk" <<'EOF'
#!/usr/bin/env bash
SPLASH_PORT="${SPLASH_PORT:-8764}"
gambit-kiosk-splash-server --port "$SPLASH_PORT"
SPLASH_URL="http://127.0.0.1:${SPLASH_PORT}/"
WEB_FAILURE_LIMIT="${WEB_FAILURE_LIMIT:-3}"
RESTART_REQUESTED="/tmp/gambit-kiosk-restart-requested.$$"
echo "Exiting nonzero so systemd restarts kiosk at splash."
EOF
    chmod 0755 "$dir/usr/local/bin/gambit-start-kiosk"
    cat > "$dir/usr/local/bin/gambit-kiosk-splash-server" <<'EOF'
#!/usr/bin/env python3
# /state
# /etc/viam.json
# journalctl
# ["ip", "route", "show", "default"]
# connect with Bluetooth to finish setup
# Waiting for Wi-Fi
# Configuring your robot
EOF
    chmod 0755 "$dir/usr/local/bin/gambit-kiosk-splash-server"
    cat > "$dir/usr/local/bin/gambit-ble-diag" <<'EOF'
#!/usr/bin/env bash
bluetoothctl show
systemctl status viam-agent.service
ls -l /etc/viam.json
journalctl -u viam-agent.service
EOF
    chmod 0755 "$dir/usr/local/bin/gambit-ble-diag"
    cat > "$dir/usr/local/bin/gambit-dim" <<'EOF'
#!/usr/bin/env bash
FULL_LEVEL="${FULL_LEVEL:-25%}"
EOF
    chmod 0755 "$dir/usr/local/bin/gambit-dim"
    dd if=/dev/zero of="$dir/usr/share/icons/invisible-cursor/cursors/left_ptr" bs=68 count=1 >/dev/null 2>&1
    cat > "$dir/usr/local/share/gambit/systemd/user/kiosk.service" <<'EOF'
[Service]
Environment=XCURSOR_THEME=invisible-cursor
Environment=XCURSOR_SIZE=1
Restart=always
EOF
    cat > "$dir/etc/systemd/system/gambit-default-brightness.service" <<'EOF'
[Unit]
Description=Gambit: set default display brightness

[Service]
ExecStart=/bin/sh -c 'brightnessctl --quiet set 25%%'

[Install]
WantedBy=multi-user.target
EOF
    ln -sfn ../gambit-default-brightness.service "$dir/etc/systemd/system/multi-user.target.wants/gambit-default-brightness.service"
    cat > "$dir/usr/local/sbin/gambit-setup-local-kiosk-user" <<'EOF'
#!/usr/bin/env bash
KIOSK_USER="${GAMBIT_KIOSK_USER:-gambitadmin}"
echo "user-session=gambit-labwc"
systemctl mask userconfig.service
EOF
    chmod 0755 "$dir/usr/local/sbin/gambit-setup-local-kiosk-user"
    touch "$dir/etc/systemd/system/gambit-kiosk-local-user.service"
    ln -sfn ../gambit-kiosk-local-user.service "$dir/etc/systemd/system/multi-user.target.wants/gambit-kiosk-local-user.service"
    cat > "$dir/usr/local/sbin/gambit-kiosk-recovery" <<'EOF'
#!/usr/bin/env bash
systemctl restart lightdm.service
pgrep -u "$KIOSK_USER" -f 'chromium.*user-data-dir=/tmp/chromium-kiosk'
MISSING_LIMIT="${MISSING_LIMIT:-3}"
EOF
    chmod 0755 "$dir/usr/local/sbin/gambit-kiosk-recovery"
    cat > "$dir/etc/systemd/system/gambit-kiosk-recovery.service" <<'EOF'
[Service]
ExecStart=/usr/local/sbin/gambit-kiosk-recovery
EOF
    ln -sfn ../gambit-kiosk-recovery.service "$dir/etc/systemd/system/multi-user.target.wants/gambit-kiosk-recovery.service"
    ln -sfn /dev/null "$dir/etc/systemd/system/userconfig.service"
    ln -sfn /dev/null "$dir/etc/systemd/system/dev-dri-renderD128.device"
    cat > "$dir/usr/share/wayland-sessions/gambit-labwc.desktop" <<'EOF'
[Desktop Entry]
Name=Gambit Labwc
Exec=labwc
Type=Application
EOF
    cat > "$dir/etc/xdg/labwc/autostart" <<'EOF'
swaybg -c '#1a1d23' &
/usr/bin/kanshi &
/bin/sh -c 'sleep 2; wlr-randr --output DSI-2 --transform 180' &
EOF
    cat > "$dir/etc/shadow" <<'EOF'
root:!:19876:0:99999:7:::
daemon:*:19876:0:99999:7:::
EOF
    cat > "$dir/etc/viam-defaults.json" <<'EOF'
{
  "network_configuration": {
    "manufacturer": "Gambit Robotics",
    "model": "CM5",
    "fragment_id": "f55bd1ed-142c-4232-9ac1-18eba4f99c87",
    "hotspot_interface": "wlan0",
    "hotspot_prefix": "gambit-setup",
    "hotspot_password": "gambitsetup"
  }
}
EOF
}

make_bootfs() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/config.txt" <<'EOF'
dtparam=i2c_arm=on
disable_splash=1
EOF
    cat > "$dir/cmdline.txt" <<'EOF'
console=serial0,115200 console=tty1 root=PARTUUID=abc rootwait quiet splash logo.nologo plymouth.ignore-serial-consoles loglevel=0 vt.global_cursor_default=0 systemd.show_status=false rd.systemd.show_status=false udev.log_level=3
EOF
}

pass_root="$tmp/pass"
make_rootfs "$pass_root"
"$VERIFY" --rootfs "$pass_root" >/dev/null

pass_boot="$tmp/pass-boot"
make_bootfs "$pass_boot"
"$VERIFY" --rootfs "$pass_root" --bootfs "$pass_boot" >/dev/null

no_quiet_boot="$tmp/no-quiet-boot"
make_bootfs "$no_quiet_boot"
sed -i.bak 's/ quiet//' "$no_quiet_boot/cmdline.txt"
rm -f "$no_quiet_boot/cmdline.txt.bak"
if "$VERIFY" --rootfs "$pass_root" --bootfs "$no_quiet_boot" >/dev/null 2>&1; then
    echo "expected missing quiet boot cmdline fixture to fail" >&2
    exit 1
fi

no_firmware_splash_boot="$tmp/no-firmware-splash-boot"
make_bootfs "$no_firmware_splash_boot"
sed -i.bak '/disable_splash/d' "$no_firmware_splash_boot/config.txt"
rm -f "$no_firmware_splash_boot/config.txt.bak"
if "$VERIFY" --rootfs "$pass_root" --bootfs "$no_firmware_splash_boot" >/dev/null 2>&1; then
    echo "expected missing disable_splash fixture to fail" >&2
    exit 1
fi

hash_root="$tmp/hash"
make_rootfs "$hash_root"
cat >> "$hash_root/etc/shadow" <<'EOF'
gambitadmin:$y$j9T$abc$def:19876:0:99999:7:::
EOF
if "$VERIFY" --rootfs "$hash_root" >/dev/null 2>&1; then
    echo "expected password hash fixture to fail" >&2
    exit 1
fi

key_root="$tmp/key"
make_rootfs "$key_root"
mkdir -p "$key_root/etc/ssh"
touch "$key_root/etc/ssh/ssh_host_ed25519_key"
if "$VERIFY" --rootfs "$key_root" >/dev/null 2>&1; then
    echo "expected SSH host key fixture to fail" >&2
    exit 1
fi

viam_root="$tmp/viam-json"
make_rootfs "$viam_root"
cat > "$viam_root/etc/viam.json" <<'EOF'
{"cloud":{"id":"device-id"}}
EOF
if "$VERIFY" --rootfs "$viam_root" >/dev/null 2>&1; then
    echo "expected baked viam.json fixture to fail" >&2
    exit 1
fi

missing_python_dev_root="$tmp/missing-python-dev"
make_rootfs "$missing_python_dev_root"
rm -rf "$missing_python_dev_root/usr/include/python3.13"
if "$VERIFY" --rootfs "$missing_python_dev_root" >/dev/null 2>&1; then
    echo "expected missing Python.h fixture to fail" >&2
    exit 1
fi

missing_i2c_dev_root="$tmp/missing-i2c-dev"
make_rootfs "$missing_i2c_dev_root"
rm -f "$missing_i2c_dev_root/etc/modules-load.d/gambit-i2c.conf"
if "$VERIFY" --rootfs "$missing_i2c_dev_root" >/dev/null 2>&1; then
    echo "expected missing i2c-dev modules-load fixture to fail" >&2
    exit 1
fi

missing_touch_calibration_root="$tmp/missing-touch-calibration"
make_rootfs "$missing_touch_calibration_root"
rm -f "$missing_touch_calibration_root/etc/udev/rules.d/90-gambit-touchscreen-calibration.rules"
if "$VERIFY" --rootfs "$missing_touch_calibration_root" >/dev/null 2>&1; then
    echo "expected missing touchscreen calibration fixture to fail" >&2
    exit 1
fi

missing_kiosk_splash_root="$tmp/missing-kiosk-splash"
make_rootfs "$missing_kiosk_splash_root"
rm -f "$missing_kiosk_splash_root/usr/local/share/gambit/kiosk-splash/index.html"
if "$VERIFY" --rootfs "$missing_kiosk_splash_root" >/dev/null 2>&1; then
    echo "expected missing local kiosk splash fixture to fail" >&2
    exit 1
fi

missing_kiosk_setup_root="$tmp/missing-kiosk-setup"
make_rootfs "$missing_kiosk_setup_root"
rm -f "$missing_kiosk_setup_root/usr/local/sbin/gambit-setup-local-kiosk-user"
if "$VERIFY" --rootfs "$missing_kiosk_setup_root" >/dev/null 2>&1; then
    echo "expected missing local kiosk setup fixture to fail" >&2
    exit 1
fi

missing_userconfig_mask_root="$tmp/missing-userconfig-mask"
make_rootfs "$missing_userconfig_mask_root"
rm -f "$missing_userconfig_mask_root/etc/systemd/system/userconfig.service"
if "$VERIFY" --rootfs "$missing_userconfig_mask_root" >/dev/null 2>&1; then
    echo "expected missing userconfig mask fixture to fail" >&2
    exit 1
fi

missing_render_mask_root="$tmp/missing-render-mask"
make_rootfs "$missing_render_mask_root"
rm -f "$missing_render_mask_root/etc/systemd/system/dev-dri-renderD128.device"
if "$VERIFY" --rootfs "$missing_render_mask_root" >/dev/null 2>&1; then
    echo "expected missing render device mask fixture to fail" >&2
    exit 1
fi

missing_kiosk_recovery_root="$tmp/missing-kiosk-recovery"
make_rootfs "$missing_kiosk_recovery_root"
rm -f "$missing_kiosk_recovery_root/usr/local/sbin/gambit-kiosk-recovery"
if "$VERIFY" --rootfs "$missing_kiosk_recovery_root" >/dev/null 2>&1; then
    echo "expected missing kiosk recovery fixture to fail" >&2
    exit 1
fi

missing_wayland_root="$tmp/missing-wayland-session"
make_rootfs "$missing_wayland_root"
rm -f "$missing_wayland_root/usr/share/wayland-sessions/gambit-labwc.desktop"
if "$VERIFY" --rootfs "$missing_wayland_root" >/dev/null 2>&1; then
    echo "expected missing gambit-labwc session fixture to fail" >&2
    exit 1
fi

missing_rotation_root="$tmp/missing-rotation"
make_rootfs "$missing_rotation_root"
sed -i.bak '/wlr-randr/d' "$missing_rotation_root/etc/xdg/labwc/autostart"
rm -f "$missing_rotation_root/etc/xdg/labwc/autostart.bak"
if "$VERIFY" --rootfs "$missing_rotation_root" >/dev/null 2>&1; then
    echo "expected missing DSI-2 transform fixture to fail" >&2
    exit 1
fi

missing_defaults_root="$tmp/missing-viam-defaults"
make_rootfs "$missing_defaults_root"
rm -f "$missing_defaults_root/etc/viam-defaults.json"
if "$VERIFY" --rootfs "$missing_defaults_root" >/dev/null 2>&1; then
    echo "expected missing viam-defaults fixture to fail" >&2
    exit 1
fi

viam_defaults_root="$tmp/secret-viam-defaults"
make_rootfs "$viam_defaults_root"
cat > "$viam_defaults_root/etc/viam-defaults.json" <<'EOF'
{"cloud":{"secret":"default-secret"}}
EOF
if "$VERIFY" --rootfs "$viam_defaults_root" >/dev/null 2>&1; then
    echo "expected viam-defaults secret fixture to fail" >&2
    exit 1
fi

bad_hotspot_root="$tmp/bad-hotspot"
make_rootfs "$bad_hotspot_root"
sed -i.bak 's/"gambit-setup"/"viam-setup"/' "$bad_hotspot_root/etc/viam-defaults.json"
rm -f "$bad_hotspot_root/etc/viam-defaults.json.bak"
if "$VERIFY" --rootfs "$bad_hotspot_root" >/dev/null 2>&1; then
    echo "expected bad viam-defaults hotspot fixture to fail" >&2
    exit 1
fi

secret_root="$tmp/secret"
make_rootfs "$secret_root"
cat > "$secret_root/usr/local/bin/leaky-config" <<'EOF'
OPENAI_API_KEY=sk-testsecretthatshouldnotbebaked
EOF
if "$VERIFY" --rootfs "$secret_root" >/dev/null 2>&1; then
    echo "expected possible secret fixture to fail" >&2
    exit 1
fi

gssapi_root="$tmp/gssapi"
make_rootfs "$gssapi_root"
mkdir -p "$gssapi_root/etc/ssh"
cat > "$gssapi_root/etc/ssh/ssh_config" <<'EOF'
#   GSSAPIKeyExchange no
EOF
"$VERIFY" --rootfs "$gssapi_root" >/dev/null

chromium_key_root="$tmp/chromium-key"
make_rootfs "$chromium_key_root"
mkdir -p "$chromium_key_root/etc/chromium.d"
cat > "$chromium_key_root/etc/chromium.d/apikeys" <<'EOF'
export GOOGLE_API_KEY="AIzaSyCkfPOPZXDKNn8hhgu3JrA62wIgC93d44k"
EOF
if "$VERIFY" --rootfs "$chromium_key_root" >/dev/null 2>&1; then
    echo "expected chromium API key fixture to fail" >&2
    exit 1
fi

echo "verify-rootfs tests passed."
