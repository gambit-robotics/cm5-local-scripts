#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/verify-rootfs.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

module_dir="root/.viam/packages/data/module/e76d1b3b-0468-4efd-bb7f-fb1d2b352fcb-csi-cam-pi-0_4_0-rc1-linux-arm64"

make_rootfs() {
    local dir="$1"
    mkdir -p "$dir/$module_dir" "$dir/etc/gambit"
    echo '{"entrypoint":"viam-csi"}' > "$dir/$module_dir/meta.json"
    cat > "$dir/$module_dir.status.json" <<'EOF'
{
  "package_id": "e76d1b3b-0468-4efd-bb7f-fb1d2b352fcb/csi-cam-pi",
  "version": "0.4.0-rc1-linux-arm64",
  "sync_status": "done"
}
EOF
    printf '# baked\ne76d1b3b-0468-4efd-bb7f-fb1d2b352fcb/csi-cam-pi 0.4.0-rc1-linux-arm64\n' > "$dir/etc/gambit/viam-modules.txt"
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
    "fragment_id": "4af2846b-610d-4ec7-8193-cd195efa0679",
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

# expect_fail ROOTFS WHAT [VERIFY ARGS...] fails the test if verification passes.
expect_fail() {
    local root="$1" what="$2"
    shift 2
    if "$VERIFY" --rootfs "$root" "$@" >/dev/null 2>&1; then
        echo "expected $what fixture to fail" >&2
        exit 1
    fi
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
expect_fail "$pass_root" "missing quiet boot cmdline" --bootfs "$no_quiet_boot"

no_firmware_splash_boot="$tmp/no-firmware-splash-boot"
make_bootfs "$no_firmware_splash_boot"
sed -i.bak '/disable_splash/d' "$no_firmware_splash_boot/config.txt"
rm -f "$no_firmware_splash_boot/config.txt.bak"
expect_fail "$pass_root" "missing disable_splash" --bootfs "$no_firmware_splash_boot"

hash_root="$tmp/hash"
make_rootfs "$hash_root"
cat >> "$hash_root/etc/shadow" <<'EOF'
gambitadmin:$y$j9T$abc$def:19876:0:99999:7:::
EOF
expect_fail "$hash_root" "password hash"

key_root="$tmp/key"
make_rootfs "$key_root"
mkdir -p "$key_root/etc/ssh"
touch "$key_root/etc/ssh/ssh_host_ed25519_key"
expect_fail "$key_root" "SSH host key"

viam_root="$tmp/viam-json"
make_rootfs "$viam_root"
cat > "$viam_root/etc/viam.json" <<'EOF'
{"cloud":{"id":"device-id"}}
EOF
expect_fail "$viam_root" "baked viam.json"

missing_python_dev_root="$tmp/missing-python-dev"
make_rootfs "$missing_python_dev_root"
rm -rf "$missing_python_dev_root/usr/include/python3.13"
expect_fail "$missing_python_dev_root" "missing Python.h"

missing_i2c_dev_root="$tmp/missing-i2c-dev"
make_rootfs "$missing_i2c_dev_root"
rm -f "$missing_i2c_dev_root/etc/modules-load.d/gambit-i2c.conf"
expect_fail "$missing_i2c_dev_root" "missing i2c-dev modules-load"

missing_touch_calibration_root="$tmp/missing-touch-calibration"
make_rootfs "$missing_touch_calibration_root"
rm -f "$missing_touch_calibration_root/etc/udev/rules.d/90-gambit-touchscreen-calibration.rules"
expect_fail "$missing_touch_calibration_root" "missing touchscreen calibration"

missing_kiosk_splash_root="$tmp/missing-kiosk-splash"
make_rootfs "$missing_kiosk_splash_root"
rm -f "$missing_kiosk_splash_root/usr/local/share/gambit/kiosk-splash/index.html"
expect_fail "$missing_kiosk_splash_root" "missing local kiosk splash"

missing_kiosk_setup_root="$tmp/missing-kiosk-setup"
make_rootfs "$missing_kiosk_setup_root"
rm -f "$missing_kiosk_setup_root/usr/local/sbin/gambit-setup-local-kiosk-user"
expect_fail "$missing_kiosk_setup_root" "missing local kiosk setup"

missing_userconfig_mask_root="$tmp/missing-userconfig-mask"
make_rootfs "$missing_userconfig_mask_root"
rm -f "$missing_userconfig_mask_root/etc/systemd/system/userconfig.service"
expect_fail "$missing_userconfig_mask_root" "missing userconfig mask"

missing_render_mask_root="$tmp/missing-render-mask"
make_rootfs "$missing_render_mask_root"
rm -f "$missing_render_mask_root/etc/systemd/system/dev-dri-renderD128.device"
expect_fail "$missing_render_mask_root" "missing render device mask"

missing_kiosk_recovery_root="$tmp/missing-kiosk-recovery"
make_rootfs "$missing_kiosk_recovery_root"
rm -f "$missing_kiosk_recovery_root/usr/local/sbin/gambit-kiosk-recovery"
expect_fail "$missing_kiosk_recovery_root" "missing kiosk recovery"

missing_wayland_root="$tmp/missing-wayland-session"
make_rootfs "$missing_wayland_root"
rm -f "$missing_wayland_root/usr/share/wayland-sessions/gambit-labwc.desktop"
expect_fail "$missing_wayland_root" "missing gambit-labwc session"

missing_rotation_root="$tmp/missing-rotation"
make_rootfs "$missing_rotation_root"
sed -i.bak '/wlr-randr/d' "$missing_rotation_root/etc/xdg/labwc/autostart"
rm -f "$missing_rotation_root/etc/xdg/labwc/autostart.bak"
expect_fail "$missing_rotation_root" "missing DSI-2 transform"

missing_defaults_root="$tmp/missing-viam-defaults"
make_rootfs "$missing_defaults_root"
rm -f "$missing_defaults_root/etc/viam-defaults.json"
expect_fail "$missing_defaults_root" "missing viam-defaults"

viam_defaults_root="$tmp/secret-viam-defaults"
make_rootfs "$viam_defaults_root"
cat > "$viam_defaults_root/etc/viam-defaults.json" <<'EOF'
{"cloud":{"secret":"default-secret"}}
EOF
expect_fail "$viam_defaults_root" "viam-defaults secret"

bad_hotspot_root="$tmp/bad-hotspot"
make_rootfs "$bad_hotspot_root"
sed -i.bak 's/"gambit-setup"/"viam-setup"/' "$bad_hotspot_root/etc/viam-defaults.json"
rm -f "$bad_hotspot_root/etc/viam-defaults.json.bak"
expect_fail "$bad_hotspot_root" "bad viam-defaults hotspot"

secret_root="$tmp/secret"
make_rootfs "$secret_root"
cat > "$secret_root/usr/local/bin/leaky-config" <<'EOF'
OPENAI_API_KEY=sk-testsecretthatshouldnotbebaked
EOF
expect_fail "$secret_root" "possible secret"

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
expect_fail "$chromium_key_root" "chromium API key"

no_modules_root="$tmp/no-viam-modules"
make_rootfs "$no_modules_root"
rm -f "$no_modules_root/etc/gambit/viam-modules.txt"
expect_fail "$no_modules_root" "no baked Viam modules"

missing_module_root="$tmp/missing-viam-module"
make_rootfs "$missing_module_root"
rm -f "$missing_module_root/$module_dir/meta.json"
expect_fail "$missing_module_root" "missing baked Viam module"

stale_status_root="$tmp/stale-viam-module-status"
make_rootfs "$stale_status_root"
sed -i.bak 's/0.4.0-rc1-linux-arm64/0.3.5-linux-arm64/' "$stale_status_root/$module_dir.status.json"
rm -f "$stale_status_root/$module_dir.status.json.bak"
expect_fail "$stale_status_root" "baked Viam module status for another version"

baked_creds_root="$tmp/baked-viam-creds"
make_rootfs "$baked_creds_root"
mkdir -p "$baked_creds_root/root/.viam/packages/data/module/gcloud-creds"
cat > "$baked_creds_root/root/.viam/packages/data/module/gcloud-creds/account-key.json" <<'EOF'
{"private_key": "-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----\n"}
EOF
expect_fail "$baked_creds_root" "service account key in a baked Viam package"

# bake-viam-modules.sh against a stand-in viam CLI: its output must pass
# verification, with each version resolved and named as viam-server would.
fake_bin="$tmp/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/viam" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
login="${VIAM_HOME:-/nonexistent}/fake-login"
case "$1 ${2:-}" in
    "login api-key") touch "$login" ;;
    "logout ") rm -f "$login" ;;
    "whoami ") [[ -n "${FAKE_VIAM_LOGIN:-}" || -f "$login" ]] ;;
    "fragment get")
        case "$4" in
            4af2846b-610d-4ec7-8193-cd195efa0679) echo '{"modules": [
                {"type": "registry", "module_id": "viam:csi-cam-pi", "version": "0.4.0-rc1"},
                {"type": "registry", "module_id": "gambit-robotics:chef", "version": "latest-with-prerelease"},
                {"type": "local", "name": "dev", "executable_path": "/tmp/dev"}],
                "packages": [{"name": "gcloud-creds", "package": "33604ab0-737c-4481-baa2-b526ccb00362/gcloud-creds", "type": "module", "version": "1.0.0"}],
                "fragments": [{"id": "nested"}]}' ;;
            nested) echo '{"modules": [
                {"type": "registry", "module_id": "erh:viam-system", "version": "latest"},
                {"type": "registry", "module_id": "gambit-robotics:chef", "version": "latest-with-prerelease"}]}' ;;
            *) exit 1 ;;
        esac ;;
    "module versions")
        case "$4 ${5:-}" in
            "gambit-robotics:chef --latest") printf 'any\t0.0.274\nlinux/amd64\t0.5.3-rc158\nlinux/arm64\t0.5.3-rc158\n' ;;
            "erh:viam-system ") printf '%s\n' \
                $'0.0.8-rc1\tlinux/arm64 (2026-10-01)' \
                $'0.0.7\tlinux/amd64 (2026-08-19), linux/arm64-codename-bullseye (2026-08-19)' \
                $'0.0.6\tlinux/amd64 (2026-08-18), linux/arm64 (2026-08-18)' ;;
            *) exit 1 ;;
        esac ;;
    "module download")
        out="${10}/$6-linux-arm64"
        mkdir -p "$out/src"
        echo '{"entrypoint": "bin/module"}' > "$out/src/meta.json"
        tar -czf "$out/${4/:/-}.tar.gz" -C "$out/src" meta.json
        rm "$out/src/meta.json"
        rmdir "$out/src" ;;
    *) exit 1 ;;
esac
EOF
chmod 0755 "$fake_bin/viam"

bake_root="$tmp/bake"
make_rootfs "$bake_root"
PATH="$fake_bin:$PATH" VIAM_KEY_ID=test VIAM_KEY_VALUE=test "$SCRIPT_DIR/bake-viam-modules.sh" --rootfs "$bake_root" >/dev/null 2>&1
"$VERIFY" --rootfs "$bake_root" >/dev/null
# Without a key it uses the existing CLI login, and fails without one.
PATH="$fake_bin:$PATH" FAKE_VIAM_LOGIN=1 "$SCRIPT_DIR/bake-viam-modules.sh" --rootfs "$bake_root" >/dev/null 2>&1
if PATH="$fake_bin:$PATH" "$SCRIPT_DIR/bake-viam-modules.sh" --rootfs "$bake_root" >/dev/null 2>&1; then
    echo "expected the bake to fail with no Viam login" >&2
    exit 1
fi
for want in e76d1b3b-0468-4efd-bb7f-fb1d2b352fcb-csi-cam-pi-0_4_0-rc1-linux-arm64 \
    33604ab0-737c-4481-baa2-b526ccb00362-chef-0_5_3-rc158-linux-arm64 \
    c2ba7a2c-e229-484c-b99a-5873631f4ea8-viam-system-0_0_6-linux-arm64; do
    if [[ ! -f "$bake_root/root/.viam/packages/data/module/$want/meta.json" ]]; then
        echo "expected the bake to produce $want" >&2
        exit 1
    fi
done
if [[ "$(grep -c '^[^#]' "$bake_root/etc/gambit/viam-modules.txt")" != 3 ]] ||
    find "$bake_root/root/.viam" -name '*gcloud-creds*' | grep -q .; then
    echo "expected the bake to list exactly the three modules and no packages" >&2
    exit 1
fi

echo "verify-rootfs tests passed."
