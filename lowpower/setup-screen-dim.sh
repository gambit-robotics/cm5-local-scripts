#!/bin/bash
set -euo pipefail

# Screen-dim user service. Installs libinput-tools + brightnessctl + the
# gambit-input-idle daemon and a per-user gambit-idle-dim.service that
# dims the DSI backlight after IDLE_TIMEOUT_SECONDS (default 300s = 5min)
# of no input, restores on any input event.
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

[[ -f "$DIM_SCRIPT_SRC" ]] || die "dim.sh missing in $SCRIPT_DIR"
[[ -f "$DAEMON_SRC" ]] || die "gambit-input-idle.sh missing in $SCRIPT_DIR"
[[ -f "$SERVICE_TEMPLATE" ]] || die "idle-dim.service.template missing"

echo "=== Gambit Screen Dim Setup (user=$TARGET_USER) ==="

# ---------------------------------------------------------------------------
# 1. Install dependencies.
# ---------------------------------------------------------------------------
echo ""
echo "[1/5] Ensuring libinput-tools + brightnessctl are installed"
if [[ -z "${SKIP_APT_UPDATE:-}" ]]; then
    apt-get update -qq
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libinput-tools brightnessctl

# ---------------------------------------------------------------------------
# 2. Install dim script to /usr/local/bin.
# ---------------------------------------------------------------------------
echo ""
echo "[2/5] Installing dim script to $DIM_SCRIPT_DST"
install -m 0755 "$DIM_SCRIPT_SRC" "$DIM_SCRIPT_DST"

# ---------------------------------------------------------------------------
# 3. Install idle-watcher daemon to /usr/local/bin.
# ---------------------------------------------------------------------------
echo ""
echo "[3/5] Installing idle-watcher daemon to $DAEMON_DST"
install -m 0755 "$DAEMON_SRC" "$DAEMON_DST"

# ---------------------------------------------------------------------------
# 4. Render user service from template.
# ---------------------------------------------------------------------------
echo ""
echo "[4/5] Installing user service for $TARGET_USER (timeout=${IDLE_TIMEOUT_SECONDS}s)"
mkdir -p "$USER_SYSTEMD_DIR"
sed \
    -e "s|%IDLE_TIMEOUT_SECONDS%|$IDLE_TIMEOUT_SECONDS|g" \
    -e "s|%DIM_SCRIPT%|$DIM_SCRIPT_DST|g" \
    "$SERVICE_TEMPLATE" > "$SERVICE_FILE"
chown -R "$TARGET_USER:$TARGET_USER" "$USER_HOME/.config/systemd"

# ---------------------------------------------------------------------------
# 5. Reload + enable as the target user.
# ---------------------------------------------------------------------------
echo ""
echo "[5/5] Reloading user systemd and enabling gambit-idle-dim.service"
loginctl enable-linger "$TARGET_USER" 2>/dev/null || true

# Run the user-systemd commands as the target user. Need a runtime dir;
# expect lingering or an active session.
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")" \
    systemctl --user daemon-reload || true
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u "$TARGET_USER")" \
    systemctl --user enable gambit-idle-dim.service || true

echo ""
echo "=== Screen Dim Installed ==="
echo "  service: ~$TARGET_USER/.config/systemd/user/gambit-idle-dim.service"
echo "  daemon:  $DAEMON_DST"
echo "  script:  $DIM_SCRIPT_DST"
echo "  timeout: ${IDLE_TIMEOUT_SECONDS}s"
echo ""
echo "Next session start (kiosk relogin or reboot) will arm the watcher."
echo "Force test: sudo -u $TARGET_USER $DIM_SCRIPT_DST dim"
echo "Force test restore: sudo -u $TARGET_USER $DIM_SCRIPT_DST restore"
