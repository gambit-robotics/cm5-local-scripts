#!/bin/bash
set -uo pipefail

# Dynamic CPU hotplug daemon for the lowpower module.
#
# Polls chef every POLL_INTERVAL seconds. Active flow phase
# (analyzing | tools | ingredients | prep | pre_heat | cooking) → bring
# ACTIVE_CORES online; otherwise scale down to IDLE_CORES. Both knobs
# come from /etc/default/gambit-cpu-scaler.
#
# cpu0 is never touched — the Linux kernel can't offline the boot CPU
# on most ARM platforms (returns EBUSY).
#
# Chef snapshots can carry recipe titles / voice transcripts, so the
# raw `viam` output is grep'd and discarded — only per-core decisions
# reach journald.

# ----------------------------------------------------------------------
# Knobs (env)
# ----------------------------------------------------------------------
ACTIVE_CORES="${ACTIVE_CORES:-4}"
IDLE_CORES="${IDLE_CORES:-1}"

# ----------------------------------------------------------------------
# Internal constants (not exposed via EnvironmentFile)
# ----------------------------------------------------------------------
POLL_INTERVAL=10
FAIL_OPEN_THRESHOLD=3

LOG_TAG="gambit-cpu-scaler"

logmsg() { logger -t "$LOG_TAG" -- "$1"; }
logerr() { logger -t "$LOG_TAG" -p err -- "$1"; }
logwarn() { logger -t "$LOG_TAG" -p warning -- "$1"; }

# ----------------------------------------------------------------------
# Validation — anchored regex defuses env-var injection
# ----------------------------------------------------------------------
if [[ ! "$ACTIVE_CORES" =~ ^[1-4]$ ]]; then
    logerr "ACTIVE_CORES=$ACTIVE_CORES invalid; expected integer 1-4"
    exit 64
fi
if [[ ! "$IDLE_CORES" =~ ^[1-4]$ ]]; then
    logerr "IDLE_CORES=$IDLE_CORES invalid; expected integer 1-4"
    exit 64
fi
if (( IDLE_CORES > ACTIVE_CORES )); then
    logerr "IDLE_CORES ($IDLE_CORES) must be <= ACTIVE_CORES ($ACTIVE_CORES)"
    exit 64
fi

TOTAL_CORES="$(nproc --all)"
if [[ ! "$TOTAL_CORES" =~ ^[1-9][0-9]*$ ]]; then
    logerr "nproc returned unexpected value: $TOTAL_CORES"
    exit 71
fi

logmsg "starting (active=$ACTIVE_CORES idle=$IDLE_CORES total=$TOTAL_CORES poll=${POLL_INTERVAL}s)"

# ----------------------------------------------------------------------
# apply_cores: bring cpu1..cpu(target-1) online, offline the rest.
# Idempotent — only writes when the value differs.
# ----------------------------------------------------------------------
apply_cores() {
    local target="$1"
    local i
    for ((i = 1; i < TOTAL_CORES; i++)); do
        local online_path="/sys/devices/system/cpu/cpu${i}/online"
        [[ -f "$online_path" ]] || continue
        local desired
        if (( i < target )); then desired=1; else desired=0; fi
        local current
        current="$(<"$online_path")" || continue
        if [[ "$current" != "$desired" ]]; then
            if echo "$desired" > "$online_path" 2>/dev/null; then
                logmsg "cpu${i} online=$desired"
            else
                logwarn "cpu${i}: failed to set online=$desired"
            fi
        fi
    done
}

# ----------------------------------------------------------------------
# get_cooking_state: echoes "active" | "idle" | "fail"
# ----------------------------------------------------------------------
get_cooking_state() {
    local result
    if ! result="$(viam machines part run \
        --component chef-analysis \
        --method DoCommand \
        --data '{"command":"get_cooking_snapshot"}' 2>/dev/null)"; then
        echo "fail"
        return
    fi
    if [[ -z "$result" ]]; then
        echo "fail"
        return
    fi
    if echo "$result" | grep -qE '"flow_phase"[[:space:]]*:[[:space:]]*"(analyzing|tools|ingredients|prep|pre_heat|cooking)"'; then
        echo "active"
    else
        echo "idle"
    fi
}

# ----------------------------------------------------------------------
# Main loop
# ----------------------------------------------------------------------
consecutive_failures=0
last_applied=""

# Known starting state: idle. The first poll will scale up if a cook is
# already in progress.
apply_cores "$IDLE_CORES"
last_applied="idle"

while true; do
    state="$(get_cooking_state)"
    case "$state" in
        active)
            consecutive_failures=0
            if [[ "$last_applied" != "active" ]]; then
                apply_cores "$ACTIVE_CORES"
                last_applied="active"
            fi
            ;;
        idle)
            consecutive_failures=0
            if [[ "$last_applied" != "idle" ]]; then
                apply_cores "$IDLE_CORES"
                last_applied="idle"
            fi
            ;;
        fail)
            consecutive_failures=$((consecutive_failures + 1))
            if (( consecutive_failures >= FAIL_OPEN_THRESHOLD )); then
                if [[ "$last_applied" != "failopen" ]]; then
                    logwarn "fail-open: $consecutive_failures polling failures, restoring all $TOTAL_CORES cores"
                    apply_cores "$TOTAL_CORES"
                    last_applied="failopen"
                fi
            fi
            # else: leave the last-applied state — assume transient blip
            ;;
    esac
    sleep "$POLL_INTERVAL"
done
