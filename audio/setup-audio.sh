#!/bin/bash
set -euo pipefail

# Boot chime setup: plays Gambit's welcome chime early in boot via systemd.
# Gives audible "the device is powering on" feedback while the DSI panel is
# still dark during kernel init (see GMBT-156).
#
# Source of truth for boot-chime.wav:
#   chef/internal/speech/adapters/chime/sounds/welcomeSound.wav
# If that file is rebranded, sync this copy.

die() { echo "Error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAV_SRC="$SCRIPT_DIR/boot-chime.wav"
WAV_DST="/usr/local/share/gambit/boot-chime.wav"
SERVICE_FILE="/etc/systemd/system/gambit-boot-chime.service"

[[ -f "$WAV_SRC" ]] || die "boot-chime.wav missing next to setup-audio.sh"

echo "=== Gambit Boot Chime Setup ==="

# aplay lives in alsa-utils
if [[ "${SKIP_APT_UPDATE:-}" != "1" ]]; then
    apt-get update -qq
fi
apt-get install -y -qq alsa-utils >/dev/null

echo "Installing $WAV_DST..."
install -d -m 0755 "$(dirname "$WAV_DST")"
install -m 0644 "$WAV_SRC" "$WAV_DST"

echo "Writing $SERVICE_FILE..."
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Gambit boot chime
After=sound.target
After=systemd-user-sessions.service

[Service]
Type=oneshot
ExecStart=/usr/bin/aplay -q $WAV_DST

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$SERVICE_FILE"

systemctl daemon-reload
systemctl enable gambit-boot-chime.service

echo ""
echo "Done. Chime will play on next boot."
echo "Volume note: if ALSA 'Speaker' is muted or at 0% the chime is silent."
echo "Test now:    systemctl start gambit-boot-chime.service"
echo "Inspect:     journalctl -u gambit-boot-chime.service -b"
