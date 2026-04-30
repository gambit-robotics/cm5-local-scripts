#!/bin/bash
set -euo pipefail

# Lowpower config: tightens CM5 idle power draw without impacting cook
# performance. Static knobs only — screen dimming is in a sibling user-level
# unit (idle-dim.sh + swayidle).
#
# Levers applied here:
#   1. CPU governor pinned to schedutil (dynamic; matches kernel default but
#      we don't trust the default to stay across distro upgrades).
#   2. gpu_mem trimmed to 76MB in /boot/firmware/config.txt (DSI panel +
#      Plymouth + labwc fit comfortably below this).
#
# Bluetooth is intentionally NOT disabled — kept on for runtime BLE.
# WiFi power_save is left untouched — Linux defaults to power_save=on.
#
# Idempotent. Safe to re-run.

die() { echo "Error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/boot/firmware/config.txt"
CONFIG_BACKUP="/boot/firmware/config.txt.bak-pre-lowpower"
GOVERNOR_SERVICE_FILE="/etc/systemd/system/gambit-cpu-governor.service"
TARGET_GOVERNOR="schedutil"
TARGET_GPU_MEM="76"

[[ -f "$CONFIG_FILE" ]] || die "config.txt missing at $CONFIG_FILE — wrong device?"

echo "=== Gambit Lowpower Config ==="

# ---------------------------------------------------------------------------
# 1. CPU governor: schedutil oneshot at boot.
# ---------------------------------------------------------------------------
echo ""
echo "[1/2] Pinning CPU governor to $TARGET_GOVERNOR"

cat > "$GOVERNOR_SERVICE_FILE" <<EOF
[Unit]
Description=Gambit: pin CPU governor to $TARGET_GOVERNOR for power efficiency
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do echo $TARGET_GOVERNOR > "\$c" || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now gambit-cpu-governor.service
echo "  service: gambit-cpu-governor.service (enabled, started)"
echo -n "  current: "
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown"

# ---------------------------------------------------------------------------
# 2. gpu_mem trim in config.txt.
# ---------------------------------------------------------------------------
echo ""
echo "[2/2] Setting gpu_mem=$TARGET_GPU_MEM in $CONFIG_FILE"

if [[ ! -f "$CONFIG_BACKUP" ]]; then
    cp "$CONFIG_FILE" "$CONFIG_BACKUP"
    echo "  backed up to $CONFIG_BACKUP"
fi

if grep -qE '^[[:space:]]*gpu_mem=' "$CONFIG_FILE"; then
    sed -i.tmp -E "s|^[[:space:]]*gpu_mem=.*|gpu_mem=$TARGET_GPU_MEM|" "$CONFIG_FILE"
    rm -f "$CONFIG_FILE.tmp"
    echo "  updated existing gpu_mem= line"
else
    printf '\n# Lowpower: trim VRAM (DSI panel + Plymouth + labwc fit < 76 MB)\ngpu_mem=%s\n' "$TARGET_GPU_MEM" >> "$CONFIG_FILE"
    echo "  appended gpu_mem= line"
fi

echo ""
echo "=== Lowpower Config Installed ==="
echo "Reboot required for gpu_mem change to take effect."
echo "Run lowpower/audit-idle-power.sh to baseline the device's idle draw."
