#!/bin/bash
set -euo pipefail

# Installer for the dynamic CPU hotplug daemon (gambit-cpu-scaler).
#
# Idempotent. Safe to re-run. Pairs with setup-lowpower.sh — the
# governor pin and gpu_mem trim live there; this script adds the
# runtime active/idle hotplug daemon on top.

die() { echo "Error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DAEMON_SRC="$SCRIPT_DIR/cpu-scaler.sh"
SERVICE_SRC="$SCRIPT_DIR/gambit-cpu-scaler.service"
DEFAULTS_SRC="$SCRIPT_DIR/gambit-cpu-scaler.defaults"

SERVICE_DST="/etc/systemd/system/gambit-cpu-scaler.service"
DEFAULTS_DST="/etc/default/gambit-cpu-scaler"

CMDLINE_FILE="/boot/firmware/cmdline.txt"
CMDLINE_BACKUP="/boot/firmware/cmdline.txt.bak-pre-cpu-scaler"

[[ -x "$DAEMON_SRC" ]] || die "cpu-scaler.sh missing or not executable at $DAEMON_SRC"
[[ -f "$SERVICE_SRC" ]] || die "gambit-cpu-scaler.service missing at $SERVICE_SRC"
[[ -f "$DEFAULTS_SRC" ]] || die "gambit-cpu-scaler.defaults missing at $DEFAULTS_SRC"

echo "=== Gambit CPU Scaler Setup ==="

# ---------------------------------------------------------------------------
# 1. Strip maxcpus= from cmdline.txt so the kernel exposes all cores
#    for runtime hotplug. Backup-once.
# ---------------------------------------------------------------------------
echo ""
echo "[1/4] Checking $CMDLINE_FILE for maxcpus="

cmdline_changed=0
if [[ -f "$CMDLINE_FILE" ]]; then
    if grep -qE '(^|[[:space:]])maxcpus=' "$CMDLINE_FILE"; then
        if [[ ! -f "$CMDLINE_BACKUP" ]]; then
            cp "$CMDLINE_FILE" "$CMDLINE_BACKUP"
            echo "  backed up to $CMDLINE_BACKUP"
        fi
        # Whitespace-collapse + trim after the strip so no stray
        # spaces are left for the bootloader to parse oddly.
        sed -i.tmp -E \
            -e 's/[[:space:]]*maxcpus=[0-9]+//g' \
            -e 's/  +/ /g' \
            -e 's/^[[:space:]]+//' \
            -e 's/[[:space:]]+$//' \
            "$CMDLINE_FILE"
        rm -f "${CMDLINE_FILE}.tmp"
        echo "  removed maxcpus= token"
        cmdline_changed=1
    else
        echo "  no maxcpus= token present — nothing to do"
    fi
else
    echo "  $CMDLINE_FILE missing — skipping (wrong device?)"
fi

# ---------------------------------------------------------------------------
# 2. Install the systemd unit.
# ---------------------------------------------------------------------------
echo ""
echo "[2/4] Installing $SERVICE_DST"
install -m 0644 "$SERVICE_SRC" "$SERVICE_DST"

# ---------------------------------------------------------------------------
# 3. Install the defaults file. Don't overwrite admin edits on re-run.
# ---------------------------------------------------------------------------
echo ""
echo "[3/4] Installing $DEFAULTS_DST"
if [[ -f "$DEFAULTS_DST" ]]; then
    echo "  already present — admin edits preserved"
else
    install -m 0644 "$DEFAULTS_SRC" "$DEFAULTS_DST"
    echo "  installed (edit to tune ACTIVE_CORES / IDLE_CORES)"
fi

# ---------------------------------------------------------------------------
# 4. Reload systemd and enable+start the unit.
# ---------------------------------------------------------------------------
echo ""
echo "[4/4] Reloading systemd and enabling gambit-cpu-scaler.service"
systemctl daemon-reload
systemctl enable --now gambit-cpu-scaler.service
echo "  service: gambit-cpu-scaler.service (enabled, started)"

echo ""
echo "=== CPU Scaler Installed ==="
echo "  daemon:   $DAEMON_SRC"
echo "  service:  $SERVICE_DST"
echo "  defaults: $DEFAULTS_DST"
echo ""
echo "Tune via /etc/default/gambit-cpu-scaler, then:"
echo "  sudo systemctl restart gambit-cpu-scaler"
echo ""
echo "Note: the daemon shells out to 'viam machines part run' to query"
echo "chef state. If the device lacks Viam CLI auth (no ~/.viam/cli.json"
echo "for root), polls fail and the daemon falls open to all cores —"
echo "no power saving, but no harm. To verify auth: 'sudo viam version'"
echo "should show a logged-in profile."

if (( cmdline_changed )); then
    echo ""
    echo "Reboot required for the kernel to expose all 4 cores (cmdline.txt changed)."
fi
