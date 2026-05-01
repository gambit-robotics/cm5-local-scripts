#!/bin/bash
set -euo pipefail

# Self-contained behavioural test for gambit-input-idle.sh.
#
# Drives the daemon with a synthetic event stream + a mock dim script,
# then asserts the dim/restore call sequence. No /dev/input access, no
# libinput dependency — the daemon's INPUT_CMD env var lets us swap the
# input source.
#
# Runs under ~4.5 seconds. Exits 0 on pass, 1 on fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DAEMON="$SCRIPT_DIR/gambit-input-idle.sh"

[[ -x "$DAEMON" ]] || { echo "FAIL: $DAEMON not executable"; exit 1; }

# Find a bash 4+ to run the daemon under. Mac /bin/bash is 3.2 and conflates
# read-timeout with EOF, defeating the daemon's transition logic; the kiosk
# target (Trixie) is 5.x.
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
log="$tmp/log"
input="$tmp/input-stream.sh"

cat > "$mock" <<EOF
#!/bin/sh
echo "\$1" >> "$log"
EOF
chmod +x "$mock"

# Synthetic event stream: 2s silence, one event, 2s silence, EOF.
# With IDLE_TIMEOUT_SECONDS=1 this exercises:
#   t=0   restore (daemon startup)
#   t=1   dim    (first timeout)
#   t=2   restore (event arrives)
#   t=3   dim    (second timeout)
#   t=4   EOF -> daemon exits 1
cat > "$input" <<'EOF'
#!/bin/sh
sleep 2
echo event
sleep 2
EOF
chmod +x "$input"

IDLE_TIMEOUT_SECONDS=1 \
DIM_SCRIPT="$mock" \
INPUT_CMD="$input" \
    "$BASH_BIN" "$DAEMON" &
pid=$!

sleep 4.5
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true

actual="$(tr '\n' ' ' < "$log")"
expected="restore dim restore dim "

if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $actual"
    exit 0
fi

echo "FAIL: expected '$expected'"
echo "      actual   '$actual'"
exit 1
