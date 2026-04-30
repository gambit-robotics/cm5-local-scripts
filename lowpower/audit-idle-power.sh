#!/bin/bash
set -euo pipefail

# Read-only audit of CM5 idle power posture. Safe to run any time. Use
# before/after applying setup-lowpower.sh to measure the delta, or as a
# post-deploy baseline on a brown-out-prone device (UR-2, UR-3) to spot
# obvious regressions.
#
# Output is grep-able single-line key=value pairs, plus a few section
# headers for human readability.

die() { echo "Error: $*" >&2; exit 1; }

heading() { echo ""; echo "=== $* ==="; }

# Most reads need root for vcgencmd / sys files; allow non-root read of what
# we can but warn.
if [[ $EUID -ne 0 ]]; then
    echo "Note: not running as root; some readings may be missing." >&2
fi

heading "host"
echo "hostname=$(hostname)"
echo "uptime=$(uptime -p 2>/dev/null || echo unknown)"
echo "kernel=$(uname -r)"

heading "cpu"
echo "nproc=$(nproc)"
for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
    cpu="$(basename "$cpu_dir")"
    online=$(cat "$cpu_dir/online" 2>/dev/null || echo 1)
    gov=$(cat "$cpu_dir/cpufreq/scaling_governor" 2>/dev/null || echo unknown)
    cur=$(cat "$cpu_dir/cpufreq/scaling_cur_freq" 2>/dev/null || echo 0)
    echo "$cpu online=$online governor=$gov cur_khz=$cur"
done

heading "throttle / undervoltage"
if command -v vcgencmd >/dev/null 2>&1; then
    vcgencmd get_throttled || true
    vcgencmd measure_temp || true
    vcgencmd measure_volts core || true
else
    echo "vcgencmd not available"
fi

heading "config.txt"
if [[ -r /boot/firmware/config.txt ]]; then
    grep -E '^(gpu_mem|arm_freq|over_voltage|disable_bt|dtoverlay)=' /boot/firmware/config.txt | sort -u || true
else
    echo "config.txt not readable (run as root)"
fi

heading "wifi"
if command -v iw >/dev/null 2>&1; then
    iw dev wlan0 get power_save 2>&1 || true
    iw dev wlan0 link 2>&1 | head -10 || true
else
    echo "iw not available"
fi

heading "bluetooth"
if command -v bluetoothctl >/dev/null 2>&1; then
    systemctl is-active bluetooth.service || true
    bluetoothctl show 2>&1 | grep -E 'Powered|Discovering' | head -5 || true
else
    echo "bluetoothctl not available"
fi

heading "running services (top boot-time consumers)"
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze blame 2>/dev/null | head -15 || true
fi

heading "ina219 power (if mounted)"
# The ina219-ups-sensor module reports voltage / current / power when present.
# Format depends on driver; just dump readings here for review.
for hwmon in /sys/class/hwmon/hwmon*/name; do
    name=$(cat "$hwmon" 2>/dev/null || echo "")
    case "$name" in
        ina2*|*INA2*)
            dir=$(dirname "$hwmon")
            echo "ina219 at $dir"
            for f in "$dir"/in1_input "$dir"/curr1_input "$dir"/power1_input; do
                [[ -r "$f" ]] && echo "  $(basename "$f")=$(cat "$f")"
            done
            ;;
    esac
done

heading "done"
echo "Use this output as a before/after baseline when applying lowpower changes."
