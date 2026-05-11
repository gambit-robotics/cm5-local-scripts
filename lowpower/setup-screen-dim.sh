#!/bin/bash
set -euo pipefail

# Screen-dim user service. Installs libinput-tools + brightnessctl + the
# gambit-input-idle daemon and a per-user gambit-idle-dim.service that
# dims the DSI backlight after IDLE_TIMEOUT_SECONDS (default 300s = 5min)
# of no input, restores on any input event, and suppresses dim while Chef
# reports an active cook or active cooking session.
#
# Why not swayidle: Chromium kiosk holds zwlr_idle_inhibit_v1 on labwc,
# so swayidle's timeout never fires. The gambit-input-idle daemon reads
# /dev/input/* via libinput debug-events directly, beneath the
# compositor — not subject to the inhibit protocol. (GMBT-377)
#
# Runs as root (apt-install) but configures the per-user service tree
# under ~$TARGET_USER/.config/systemd/user/ — same pattern as
# kiosk/setup-kiosk-wayland.sh.
#
# Usage: sudo TARGET_USER=gambitadmin ./setup-screen-dim.sh

die() { echo "Error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo"
[[ -n "${TARGET_USER:-}" ]] || die "TARGET_USER env var required (e.g. gambitadmin)"

if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    die "user '$TARGET_USER' does not exist"
fi

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d "$USER_HOME" ]] || die "home dir for $TARGET_USER not found"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIM_SCRIPT_SRC="$SCRIPT_DIR/dim.sh"
DAEMON_SRC="$SCRIPT_DIR/gambit-input-idle.sh"
SERVICE_TEMPLATE="$SCRIPT_DIR/idle-dim.service.template"

DIM_SCRIPT_DST="/usr/local/bin/gambit-dim"
DAEMON_DST="/usr/local/bin/gambit-input-idle"
USER_SYSTEMD_DIR="$USER_HOME/.config/systemd/user"
SERVICE_FILE="$USER_SYSTEMD_DIR/gambit-idle-dim.service"

IDLE_TIMEOUT_SECONDS="${IDLE_TIMEOUT_SECONDS:-300}"
# Paths chef will touch while cook/session work is active. Daemon won't dim
# while either file exists; restores within one tick if either file appears
# during a dimmed period.
COOK_STATE_FILE="${COOK_STATE_FILE:-/run/gambit/cook-active}"
SESSION_STATE_FILE="${SESSION_STATE_FILE:-/run/gambit/session-active}"

[[ -f "$DIM_SCRIPT_SRC" ]] || die "dim.sh missing in $SCRIPT_DIR"
[[ -f "$DAEMON_SRC" ]] || die "gambit-input-idle.sh missing in $SCRIPT_DIR"
[[ -f "$SERVICE_TEMPLATE" ]] || die "idle-dim.service.template missing"

echo "=== Gambit Screen Dim Setup (user=$TARGET_USER) ==="

# ---------------------------------------------------------------------------
# 1. Install dependencies.
# ---------------------------------------------------------------------------
echo ""
echo "[1/7] Ensuring libinput-tools + brightnessctl are installed"
if [[ -z "${SKIP_APT_UPDATE:-}" ]]; then
    apt-get update -qq
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libinput-tools brightnessctl

# ---------------------------------------------------------------------------
# 2. Grant input-device access to the target user.
# ---------------------------------------------------------------------------
# `libinput debug-events` reads /dev/input/event*, which is owned by the
# `input` group on Debian (mode 0660). Without group membership the daemon
# silently produces zero events → screen would dim after IDLE_TIMEOUT_SECONDS
# regardless of touch input, which is the exact bug this whole change is
# meant to fix, just inverted (always-dim instead of never-dim). usermod is
# idempotent — re-runs are no-ops if the user is already in the group. The
# new group membership only takes effect for sessions started AFTER this
# change, so the kiosk session needs a relogin (or device reboot) to pick
# it up. The preflight below catches the common-case failure (no input
# devices visible) loudly, which beats the daemon silently mis-firing.
echo ""
echo "[2/7] Granting input-device access to $TARGET_USER"
usermod -aG input "$TARGET_USER"
if compgen -G '/dev/input/event*' >/dev/null; then
    n=$(find /dev/input -maxdepth 1 -name 'event*' 2>/dev/null | wc -l | tr -d ' ')
    echo "  /dev/input/event* visible (count=$n)"
else
    echo "  WARNING: no /dev/input/event* devices visible from this shell."
    echo "  libinput debug-events will produce no events; the daemon will"
    echo "  dim after timeout regardless of touch. Verify input subsystem."
fi
echo "  NOTE: existing sessions need to log out/in (or reboot) for the"
echo "  group membership to take effect."

# ---------------------------------------------------------------------------
# 3. Provision /run/gambit via tmpfiles.d so chef's active-state file writes
#    has a directory to land in regardless of who chef runs as.
# ---------------------------------------------------------------------------
# Chef writes /run/gambit/cook-active when a cook timer is active and
# /run/gambit/session-active when a cooking session is active. The daemon
# polls them (see CLAUDE.md cross-repo contract). Chef does
# os.MkdirAll on the directory but logs failures only at debug level —
# if chef ever runs non-root the failure is silent and the daemon never
# sees the active-state flags. Provision the directory here once at install
# time so the chef-side MkdirAll is a no-op that succeeds for any user.
# Mode 0755: root writes inside, others can stat / read for presence.
TMPFILES_CONF="/etc/tmpfiles.d/gambit-runtime.conf"
echo ""
echo "[3/7] Provisioning /run/gambit via $TMPFILES_CONF"
cat > "$TMPFILES_CONF" <<'EOF'
# Gambit runtime tmpfs directory. Holds chef → gambit-input-idle daemon
# presence signals (/run/gambit/cook-active and /run/gambit/session-active).
# tmpfs, so nothing here persists across reboot. Mode 0755 lets root write
# the files and any user stat them.
d /run/gambit 0755 root root -
EOF
# Apply now so the directory exists immediately rather than waiting for
# the next boot. --create is idempotent.
systemd-tmpfiles --create "$TMPFILES_CONF"

# ---------------------------------------------------------------------------
# 4. Install dim script to /usr/local/bin.
# ---------------------------------------------------------------------------
echo ""
echo "[4/7] Installing dim script to $DIM_SCRIPT_DST"
install -m 0755 "$DIM_SCRIPT_SRC" "$DIM_SCRIPT_DST"

# ---------------------------------------------------------------------------
# 5. Install idle-watcher daemon to /usr/local/bin.
# ---------------------------------------------------------------------------
echo ""
echo "[5/7] Installing idle-watcher daemon to $DAEMON_DST"
install -m 0755 "$DAEMON_SRC" "$DAEMON_DST"

# ---------------------------------------------------------------------------
# 6. Render user service from template.
# ---------------------------------------------------------------------------
echo ""
echo "[6/7] Installing user service for $TARGET_USER (timeout=${IDLE_TIMEOUT_SECONDS}s)"
mkdir -p "$USER_SYSTEMD_DIR"
sed \
    -e "s|%IDLE_TIMEOUT_SECONDS%|$IDLE_TIMEOUT_SECONDS|g" \
    -e "s|%DIM_SCRIPT%|$DIM_SCRIPT_DST|g" \
    -e "s|%COOK_STATE_FILE%|$COOK_STATE_FILE|g" \
    -e "s|%SESSION_STATE_FILE%|$SESSION_STATE_FILE|g" \
    "$SERVICE_TEMPLATE" > "$SERVICE_FILE"
chown -R "$TARGET_USER:$TARGET_USER" "$USER_HOME/.config/systemd"

# ---------------------------------------------------------------------------
# 7. Reload + enable as the target user.
# ---------------------------------------------------------------------------
echo ""
echo "[7/7] Reloading user systemd and enabling gambit-idle-dim.service"
loginctl enable-linger "$TARGET_USER" 2>/dev/null || true

# Run the user-systemd commands as the target user. Need a runtime dir;
# expect lingering or an active session.
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")" \
    systemctl --user daemon-reload || true
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")" \
    systemctl --user enable gambit-idle-dim.service || true

echo ""
echo "=== Screen Dim Installed ==="
echo "  service:    ~$TARGET_USER/.config/systemd/user/gambit-idle-dim.service"
echo "  daemon:     $DAEMON_DST"
echo "  script:     $DIM_SCRIPT_DST"
echo "  timeout:    ${IDLE_TIMEOUT_SECONDS}s"
echo "  cook flag:  $COOK_STATE_FILE"
echo "  session:    $SESSION_STATE_FILE"
echo ""
echo "Next session start (kiosk relogin or reboot) will arm the watcher."
echo "Force test: sudo -u $TARGET_USER $DIM_SCRIPT_DST dim"
echo "Force test restore: sudo -u $TARGET_USER $DIM_SCRIPT_DST restore"
