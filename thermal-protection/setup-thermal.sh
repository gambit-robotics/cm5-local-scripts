#!/bin/bash
set -euo pipefail

# Thermal Protection Daemon Installer
# Installs a standalone systemd service that monitors CPU/ambient temps
# and plays alarm sounds when thresholds are exceeded.
#
# Usage: sudo ./setup-thermal.sh

die() { echo "Error: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/usr/local/share/thermal-protection"
DAEMON_SCRIPT="/usr/local/bin/thermal-protection.sh"
SERVICE_FILE="/etc/systemd/system/thermal-protection.service"

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run with sudo"

echo "Setting up thermal protection daemon"

# ---------------------------------------------------------------------------
# Install dependencies
# ---------------------------------------------------------------------------
if [[ "${SKIP_APT_UPDATE:-}" != "1" ]]; then
    apt-get update -qq
fi
apt-get install -y -qq sox espeak-ng alsa-utils >/dev/null

# ---------------------------------------------------------------------------
# Generate audio files
# ---------------------------------------------------------------------------
install -d "$INSTALL_DIR"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Generating alarm audio files..."

# Generate smoke-detector style alarm: 3 beeps, pause, repeat x3
# Each beep: 0.1s of 3kHz square wave at 80% volume
sox -n -r 44100 -c 1 "$TMPDIR/beep.wav" synth 0.1 square 3000 vol 0.8
sox -n -r 44100 -c 1 "$TMPDIR/gap.wav" trim 0 0.08
sox -n -r 44100 -c 1 "$TMPDIR/pause.wav" trim 0 0.8

# Build: beep-gap-beep-gap-beep-pause (one burst)
sox "$TMPDIR/beep.wav" "$TMPDIR/gap.wav" \
    "$TMPDIR/beep.wav" "$TMPDIR/gap.wav" \
    "$TMPDIR/beep.wav" "$TMPDIR/pause.wav" \
    "$TMPDIR/burst.wav"

# Full alarm clip: 3 bursts (~5 seconds total)
sox "$TMPDIR/burst.wav" "$TMPDIR/burst.wav" "$TMPDIR/burst.wav" \
    "$INSTALL_DIR/alarm.wav"

echo "  Created alarm.wav"

# Generate TTS audio
espeak-ng -v en -s 140 -a 200 -w "$INSTALL_DIR/warning.wav" \
    "Warning. High temperature detected." 2>/dev/null
echo "  Created warning.wav"

espeak-ng -v en -s 140 -a 200 -w "$INSTALL_DIR/alarm-voice.wav" \
    "Dangerous temperature. Remove Gambit immediately." 2>/dev/null
echo "  Created alarm-voice.wav"

# ---------------------------------------------------------------------------
# Install daemon script
# ---------------------------------------------------------------------------
echo "Installing daemon..."
install -m 755 "$SCRIPT_DIR/thermal-protection.sh" "$DAEMON_SCRIPT"

# ---------------------------------------------------------------------------
# Create systemd service
# ---------------------------------------------------------------------------
echo "Creating systemd service..."
cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Thermal Protection Daemon
DefaultDependencies=no
After=local-fs.target sound.target
Before=viam-agent.service

[Service]
Type=simple
ExecStart=/usr/local/bin/thermal-protection.sh
Restart=on-failure
RestartSec=10

# Run early, survive everything
TimeoutStartSec=10
TimeoutStopSec=10

# Thresholds (override defaults here if needed)
#Environment=CPU_WARN_THRESHOLD=80
#Environment=CPU_ALARM_THRESHOLD=90
#Environment=AMBIENT_WARN_THRESHOLD=65
#Environment=AMBIENT_ALARM_THRESHOLD=80
#Environment=HYSTERESIS=3
#Environment=POLL_INTERVAL=5

# Set this to the sysfs path of your ambient temp sensor if auto-detection fails
#Environment=AMBIENT_TEMP_SOURCE=/sys/class/thermal/thermal_zone1/temp

[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# Enable and start
# ---------------------------------------------------------------------------
systemctl daemon-reload
systemctl enable thermal-protection.service

echo ""
echo "Done. Thermal protection service installed and enabled."
echo ""
echo "  Service: thermal-protection.service"
echo "  Daemon:  $DAEMON_SCRIPT"
echo "  Audio:   $INSTALL_DIR/"
echo ""
echo "Commands:"
echo "  sudo systemctl start thermal-protection    # Start now"
echo "  sudo systemctl status thermal-protection   # Check status"
echo "  sudo journalctl -u thermal-protection -f   # View logs"
echo ""
echo "To override thresholds, edit: $SERVICE_FILE"
echo "Then: sudo systemctl daemon-reload && sudo systemctl restart thermal-protection"
