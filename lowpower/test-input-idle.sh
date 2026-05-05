#!/bin/bash
set -euo pipefail

# Self-contained behavioural tests for gambit-input-idle.sh.
#
# Drives the daemon with a synthetic event stream + a mock dim script,
# then asserts the dim/restore call sequence. No /dev/input access, no
# libinput dependency — the daemon's INPUT_CMD env var lets us swap the
# input source.
#
# Two cases:
#   1. Idle without active cook: idle past timeout -> dim, event -> restore,
#      idle again -> dim. (Original behaviour.)
#   2. Active-cook gate: cook flag set across an idle window -> no dim;
#      flag cleared, idle past timeout -> dim. (GMBT-377 cook-aware.)
#
# Total runtime ~12 seconds. Exits 0 on pass, 1 on fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="$SCRIPT_DIR/gambit-input-idle.sh"

[[ -x "$DAEMON" ]] || { echo "FAIL: $DAEMON not executable"; exit 1; }

BASH_BIN=
if (( BASH_VERSINFO[0] >= 4 )); then
    BASH_BIN="$(command -v bash)"
else
    for cand in bash5 bash4 /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if command -v "$cand" >/dev/null 2>&1 \
            && "$cand" -c '(( BASH_VERSINFO[0] >= 4 ))' 2>/dev/null; then
            BASH_BIN="$cand"
            break
        fi
    done
fi
if [[ -z "$BASH_BIN" ]]; then
    echo "SKIP: gambit-input-idle requires bash 4+ for read-timeout semantics;"
    echo "      no bash 4+ found on this host. Run on a Linux box (or brew bash) for full coverage."
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mock="$tmp/mock-dim"
cat > "$mock" <<'EOF'
#!/bin/sh
echo "$1" >> "$LOG"
EOF
chmod +x "$mock"

assert_log() {
    local name="$1" expected="$2" actual
    actual="$(tr '\n' ' ' < "$LOG")"
    if [[ "$actual" == "$expected" ]]; then
        echo "PASS [$name]: $actual"
        return 0
    fi
    echo "FAIL [$name]:"
    echo "  expected '$expected'"
    echo "  actual   '$actual'"
    return 1
}

# ---------------------------------------------------------------------------
# Case 1: idle without cook -> dim/restore/dim sequence.
# ---------------------------------------------------------------------------
case1() {
    export LOG="$tmp/log1"
    : > "$LOG"
    local input="$tmp/input1.sh"
    cat > "$input" <<'EOF'
#!/bin/sh
sleep 2
echo event
sleep 2
EOF
    chmod +x "$input"

    IDLE_TIMEOUT_SECONDS=1 \
    TICK_SECONDS=1 \
    DIM_SCRIPT="$mock" \
    INPUT_CMD="$input" \
    COOK_STATE_FILE="$tmp/cook-NEVER-EXISTS" \
        "$BASH_BIN" "$DAEMON" &
    local pid=$!
    sleep 4.5
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    assert_log "idle-no-cook" "restore dim restore dim "
}

# ---------------------------------------------------------------------------
# Case 2: cook flag suppresses dim; clearing it lets dim resume.
# ---------------------------------------------------------------------------
case2() {
    export LOG="$tmp/log2"
    : > "$LOG"
    local cook="$tmp/cook-active"
    local input="$tmp/input2.sh"
    # No input events at all — pure idle.
    cat > "$input" <<'EOF'
#!/bin/sh
sleep 60
EOF
    chmod +x "$input"

    # Pre-create the cook flag so the daemon sees it from the first tick.
    touch "$cook"

    IDLE_TIMEOUT_SECONDS=1 \
    TICK_SECONDS=1 \
    DIM_SCRIPT="$mock" \
    INPUT_CMD="$input" \
    COOK_STATE_FILE="$cook" \
        "$BASH_BIN" "$DAEMON" &
    local pid=$!

    # Sit through 3 ticks past the idle timeout while cook is active.
    # No dim should fire; only the startup restore is in the log.
    sleep 3.5

    # Clear the cook flag. Within ~1 tick + idle window the daemon should
    # observe idle_for>threshold AND no cook -> dim.
    rm "$cook"
    sleep 2.5

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    assert_log "cook-gate" "restore dim "
}

# ---------------------------------------------------------------------------
# Case 3: dimmed -> cook starts -> daemon restores within one tick.
# ---------------------------------------------------------------------------
case3() {
    export LOG="$tmp/log3"
    : > "$LOG"
    local cook="$tmp/cook-active-3"
    local input="$tmp/input3.sh"
    cat > "$input" <<'EOF'
#!/bin/sh
sleep 60
EOF
    chmod +x "$input"

    IDLE_TIMEOUT_SECONDS=1 \
    TICK_SECONDS=1 \
    DIM_SCRIPT="$mock" \
    INPUT_CMD="$input" \
    COOK_STATE_FILE="$cook" \
        "$BASH_BIN" "$DAEMON" &
    local pid=$!

    # Let it idle to dim.
    sleep 2.5

    # Now start a cook. Daemon should restore on next tick.
    touch "$cook"
    sleep 2

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    assert_log "dim-then-cook-restores" "restore dim restore "
}

fail=0
case1 || fail=1
case2 || fail=1
case3 || fail=1
exit "$fail"
