#!/bin/bash
set -uo pipefail

# Idle-watcher that bypasses Wayland's idle-inhibitor protocol.
#
# Why: Chromium kiosk holds zwlr_idle_inhibit_v1 on labwc (WebRTC streams,
# Wake Lock API), so swayidle's timeout never fires and the screen never
# dims. We sit beneath the compositor and watch /dev/input/* directly via
# libinput debug-events — that channel is not subject to the inhibit
# protocol.
#
# Loop is tick-based: every TICK_SECONDS we drain whatever input arrived,
# advance an idle counter, and re-evaluate the desired backlight state
# against (idle counter) + (cook-active flag).
#
# Active-cook gate: chef writes the path COOK_STATE_FILE while a cook
# session is running and removes it when the cook ends. While the file is
# present we never dim, regardless of input idle time, and we restore on
# the next tick if we were already dimmed when chef started the cook
# (e.g. voice-activated start with no prior touch).
#
# Env:
#   IDLE_TIMEOUT_SECONDS  default 300
#   TICK_SECONDS          default 5  (granularity of idle counter + cook check)
#   DIM_SCRIPT            default /usr/local/bin/gambit-dim
#   COOK_STATE_FILE       default /run/gambit/cook-active
#   INPUT_CMD             default "libinput debug-events" (override for tests)
#
# Invariants:
#   - Backlight state changes are edge-triggered: we only call DIM_SCRIPT
#     when the desired state differs from the current state.
#   - On input-stream EOF/error we exit nonzero so systemd Restart=on-failure
#     brings us back rather than getting stuck never-dimming.
#
# Limitation: libinput enumerates /dev/input/* at startup. Devices attached
# after the daemon starts (mid-session USB hotplug) are not watched. The
# kiosk's input set is fixed (built-in DSI touchscreen, I2C buttons), so
# this is not a production concern; restart the service if you need to
# pick up a new input device.

if (( BASH_VERSINFO[0] < 4 )); then
    echo "Error: requires bash 4+ (got $BASH_VERSION)" >&2
    exit 1
fi

IDLE_TIMEOUT_SECONDS="${IDLE_TIMEOUT_SECONDS:-300}"
TICK_SECONDS="${TICK_SECONDS:-5}"
DIM_SCRIPT="${DIM_SCRIPT:-/usr/local/bin/gambit-dim}"
COOK_STATE_FILE="${COOK_STATE_FILE:-/run/gambit/cook-active}"
INPUT_CMD="${INPUT_CMD:-libinput debug-events}"

[[ -x "$DIM_SCRIPT" ]] || { echo "Error: $DIM_SCRIPT not executable" >&2; exit 1; }

cook_active() { [[ -e "$COOK_STATE_FILE" ]]; }

apply() {
    local want="$1"
    if [[ "$want" != "$state" ]]; then
        "$DIM_SCRIPT" "$want" || true
        state="$want"
    fi
}

# DIM_SCRIPT verbs: "restore" -> full brightness, "dim" -> dim level.
# The 'state' variable mirrors that vocabulary so apply() can pass it
# through verbatim.
state=restore
"$DIM_SCRIPT" restore || true

# shellcheck disable=SC2086
exec < <($INPUT_CMD 2>/dev/null)

idle_for=0
while :; do
    read -r -t "$TICK_SECONDS" _line
    rc=$?

    if (( rc == 0 )); then
        idle_for=0
        # Drain any burst queued behind this line so we don't lag real-time.
        while read -r -t 0.01 _line; do :; done
    elif (( rc > 128 )); then
        idle_for=$((idle_for + TICK_SECONDS))
    else
        echo "input stream closed (rc=$rc), exiting for systemd restart" >&2
        exit 1
    fi

    if cook_active; then
        apply restore
    elif (( idle_for >= IDLE_TIMEOUT_SECONDS )); then
        apply dim
    else
        apply restore
    fi
done
