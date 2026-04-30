#!/bin/bash
set -euo pipefail

# Brightness toggle for the kiosk's DSI panel. Used by the swayidle user
# service: timeout fires this with `dim`, resume fires `restore`.
#
# Real-hardware backlight (PWM) via brightnessctl when available — that's
# what actually saves power on the panel. Falls back to wlr-randr's
# software gamma if no /sys/class/backlight device is exposed (e.g. on
# headless test hosts where this script is exercised by syntax-check).
#
# Usage:
#   dim.sh dim         # set backlight to DIM_LEVEL (default 15%)
#   dim.sh restore     # set backlight to FULL_LEVEL (default 100%)

DIM_LEVEL="${DIM_LEVEL:-15%}"
FULL_LEVEL="${FULL_LEVEL:-100%}"

mode="${1:-restore}"
case "$mode" in
    dim) target="$DIM_LEVEL" ;;
    restore) target="$FULL_LEVEL" ;;
    *) echo "Usage: $0 {dim|restore}" >&2; exit 2 ;;
esac

if command -v brightnessctl >/dev/null 2>&1 && [ -d /sys/class/backlight ] && [ -n "$(ls /sys/class/backlight 2>/dev/null)" ]; then
    brightnessctl --quiet set "$target" || true
    exit 0
fi

# Fallback: software gamma via wlr-randr. No power saving but at least the
# screen visibly dims so the user can tell the script is wired up.
if command -v wlr-randr >/dev/null 2>&1; then
    # Convert "15%" to "0.15"
    pct="${target%\%}"
    ratio=$(awk -v p="$pct" 'BEGIN { printf "%.2f", p / 100 }')
    output=$(wlr-randr 2>/dev/null | awk '/^[A-Z]/ && $1 ~ /-[0-9]+$/ { print $1; exit }')
    [ -n "$output" ] && wlr-randr --output "$output" --brightness "$ratio" || true
fi
