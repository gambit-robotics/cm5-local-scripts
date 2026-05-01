#!/bin/bash
set -uo pipefail

# Idle-watcher that bypasses Wayland's idle-inhibitor protocol.
#
# Why: Chromium kiosk holds zwlr_idle_inhibit_v1 on labwc (WebRTC streams,
# Wake Lock API), so swayidle's timeout never fires and the screen never
# dims. We sit beneath the compositor and watch /dev/input/* directly via
# libinput debug-events — that channel is not subject to the inhibit
# protocol. After IDLE_TIMEOUT_SECONDS of zero events we run DIM_SCRIPT
# dim; on the next event we run DIM_SCRIPT restore.
#
# Env:
#   IDLE_TIMEOUT_SECONDS  default 300
#   DIM_SCRIPT            default /usr/local/bin/gambit-dim
#   INPUT_CMD             default "libinput debug-events" (override for tests)
#
# Invariants:
#   - Only ever calls "$DIM_SCRIPT dim" while currently full, and
#     "$DIM_SCRIPT restore" while currently dim — every transition is
#     a single, edge-triggered call.
#   - On input-stream EOF/error we exit nonzero so systemd Restart=on-failure
#     brings us back rather than getting stuck never-dimming.
#
# Limitation: libinput enumerates /dev/input/* at startup. Devices attached
# after the daemon starts (mid-session USB hotplug) are not watched. The
# kiosk's input set is fixed (built-in DSI touchscreen, I2C buttons), so
# this is not a production concern; restart the service if you need to
# pick up a new input device.

# bash 4+ required: we disambiguate read-timeout (rc>128) from EOF (rc=1)
# to decide between "dim now" and "exit so systemd restarts us". Bash 3
# returns rc=1 for both, which would conflate them.
if (( BASH_VERSINFO[0] < 4 )); then
    echo "Error: requires bash 4+ (got $BASH_VERSION)" >&2
    exit 1
fi

IDLE_TIMEOUT_SECONDS="${IDLE_TIMEOUT_SECONDS:-300}"
DIM_SCRIPT="${DIM_SCRIPT:-/usr/local/bin/gambit-dim}"
INPUT_CMD="${INPUT_CMD:-libinput debug-events}"

[[ -x "$DIM_SCRIPT" ]] || { echo "Error: $DIM_SCRIPT not executable" >&2; exit 1; }

state=full
"$DIM_SCRIPT" restore || true

# Word-split INPUT_CMD intentionally so "libinput debug-events" becomes
# argv[0]+argv[1]. Tests pass a single-token script path.
# shellcheck disable=SC2086
exec < <($INPUT_CMD 2>/dev/null)

while :; do
    read -r -t "$IDLE_TIMEOUT_SECONDS" _line
    rc=$?
    if (( rc == 0 )); then
        if [[ "$state" == "dim" ]]; then
            "$DIM_SCRIPT" restore || true
            state=full
        fi
    elif (( rc > 128 )); then
        if [[ "$state" == "full" ]]; then
            "$DIM_SCRIPT" dim || true
            state=dim
        fi
    else
        echo "input stream closed (rc=$rc), exiting for systemd restart" >&2
        exit 1
    fi
done
