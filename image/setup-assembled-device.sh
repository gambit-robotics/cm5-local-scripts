#!/usr/bin/env bash
set -euo pipefail

# Idempotent post-flash setup for an assembled Gambit CM5 device.
# Run as root on the Raspberry Pi after the image boots.

KIOSK_USER="${GAMBIT_KIOSK_USER:-gambitadmin}"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
    build-essential \
    chromium \
    curl \
    i2c-tools \
    jq \
    kanshi \
    labwc \
    lightdm \
    python3-dev \
    python3-venv \
    swaybg \
    wlr-randr

if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_i2c 0 || true
fi
install -d -m 0755 /etc/modules-load.d
cat > /etc/modules-load.d/gambit-i2c.conf <<'EOF'
i2c-dev
EOF
modprobe i2c-dev || true

groups=()
for group in adm dialout cdrom sudo audio video plugdev users input render netdev gpio i2c spi; do
    getent group "$group" >/dev/null && groups+=("$group")
done

if ! id "$KIOSK_USER" >/dev/null 2>&1; then
    args=(-m -s /bin/bash)
    if (( ${#groups[@]} > 0 )); then
        IFS=,
        args+=(-G "${groups[*]}")
        unset IFS
    fi
    useradd "${args[@]}" "$KIOSK_USER"
else
    for group in "${groups[@]}"; do
        usermod -aG "$group" "$KIOSK_USER" || true
    done
fi
passwd -l "$KIOSK_USER" >/dev/null 2>&1 || true

user_home="$(getent passwd "$KIOSK_USER" | cut -d: -f6)"
user_id="$(id -u "$KIOSK_USER")"

install -d -o "$KIOSK_USER" -g "$KIOSK_USER" "$user_home/.config/systemd/user/default.target.wants"
install -d -o "$KIOSK_USER" -g "$KIOSK_USER" "$user_home/.config/labwc"

if [[ -f /usr/local/share/gambit/systemd/user/kiosk.service ]]; then
    install -m 0644 -o "$KIOSK_USER" -g "$KIOSK_USER" \
        /usr/local/share/gambit/systemd/user/kiosk.service \
        "$user_home/.config/systemd/user/kiosk.service"
else
    cat > "$user_home/.config/systemd/user/kiosk.service" <<'EOF'
[Unit]
Description=Chef Display Kiosk (Wayland)
After=graphical-session.target

[Service]
Environment=WAYLAND_DISPLAY=wayland-0
ExecStart=/usr/local/bin/gambit-start-kiosk
Environment=XCURSOR_THEME=invisible-cursor
Environment=XCURSOR_SIZE=1
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF
    chown "$KIOSK_USER:$KIOSK_USER" "$user_home/.config/systemd/user/kiosk.service"
fi
ln -sfn ../kiosk.service "$user_home/.config/systemd/user/default.target.wants/kiosk.service"
chown -h "$KIOSK_USER:$KIOSK_USER" "$user_home/.config/systemd/user/default.target.wants/kiosk.service"

cat > "$user_home/.config/labwc/environment" <<'EOF'
XCURSOR_THEME=invisible-cursor
XCURSOR_SIZE=1
EOF
chown "$KIOSK_USER:$KIOSK_USER" "$user_home/.config/labwc/environment"

install -d -m 0755 /usr/share/wayland-sessions
cat > /usr/share/wayland-sessions/gambit-labwc.desktop <<'EOF'
[Desktop Entry]
Name=Gambit Labwc
Comment=Gambit kiosk Wayland session
Exec=labwc
Type=Application
DesktopNames=labwc
EOF

install -d -m 0755 /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/99-gambit-autologin.conf <<EOF
[Seat:*]
autologin-user=$KIOSK_USER
autologin-user-timeout=0
user-session=gambit-labwc
EOF

install -d -m 0755 /etc/xdg/labwc
cat > /etc/xdg/labwc/autostart <<'EOF'
swaybg -c '#1a1d23' &
/usr/bin/kanshi &
/bin/sh -c 'sleep 2; wlr-randr --output DSI-2 --transform 180' &
EOF

cat > /usr/local/sbin/gambit-kiosk-recovery <<'EOF'
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
chmod 0755 /usr/local/sbin/gambit-kiosk-recovery

cat > /etc/systemd/system/gambit-kiosk-recovery.service <<EOF
[Unit]
Description=Gambit kiosk display recovery watchdog
After=lightdm.service
Wants=lightdm.service

[Service]
Type=simple
Environment=GAMBIT_KIOSK_USER=$KIOSK_USER
ExecStart=/usr/local/sbin/gambit-kiosk-recovery
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

install -d -m 0755 /var/lib/systemd/linger
touch "/var/lib/systemd/linger/$KIOSK_USER"
loginctl enable-linger "$KIOSK_USER" >/dev/null 2>&1 || true

systemctl disable userconfig.service >/dev/null 2>&1 || true
systemctl mask userconfig.service >/dev/null 2>&1 || true
systemctl mask dev-dri-renderD128.device >/dev/null 2>&1 || true
systemctl enable gambit-kiosk-recovery.service >/dev/null 2>&1 || true
systemctl enable lightdm >/dev/null 2>&1 || true

echo "Configured Gambit kiosk user '$KIOSK_USER' (uid=$user_id). Reboot to start kiosk."
