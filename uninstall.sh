#!/bin/bash
#
# Gambit Scripts Uninstaller
# Removes user modules (buttons, kiosk)
#

set -e

# Module flags (defaults)
UNINSTALL_BUTTONS=false
UNINSTALL_KIOSK=false

# User module arguments
TARGET_USER=""

# ------------------------------------------------------------------------------
# Help
# ------------------------------------------------------------------------------
show_help() {
    cat << 'EOF'
Gambit Scripts Uninstaller

Usage: sudo ./uninstall.sh [OPTIONS] [<username>]

Modules:
  --buttons         Uninstall I2C volume button controller
  --kiosk           Uninstall Chromium kiosk
  --all             Uninstall all modules

Arguments (required for user-level modules):
  <username>        Target user whose services to remove

Examples:
  sudo ./uninstall.sh --buttons pi              # Buttons only
  sudo ./uninstall.sh --kiosk pi                # Kiosk only
  sudo ./uninstall.sh --all pi                  # All modules

EOF
    exit 0
}

die() { echo "Error: $*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) show_help ;;
        --buttons) UNINSTALL_BUTTONS=true; shift ;;
        --kiosk) UNINSTALL_KIOSK=true; shift ;;
        --all) UNINSTALL_BUTTONS=true; UNINSTALL_KIOSK=true; shift ;;
        -*)
            die "Unknown option: $1. Use --help for usage."
            ;;
        *)
            if [[ -z "$TARGET_USER" ]]; then
                TARGET_USER="$1"
            else
                die "Too many arguments. Use --help for usage."
            fi
            shift
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------------------

# Check for root
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root (use sudo)"
fi

# User modules require a username
if { $UNINSTALL_BUTTONS || $UNINSTALL_KIOSK; } && [[ -z "$TARGET_USER" ]]; then
    die "Username required for --buttons or --kiosk. Use --help for usage."
fi

# Validate user exists (for user modules)
if [[ -n "$TARGET_USER" ]]; then
    id "$TARGET_USER" &>/dev/null || die "User '$TARGET_USER' does not exist"
    USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    USER_ID=$(id -u "$TARGET_USER")
fi

# ------------------------------------------------------------------------------
# Module: Buttons
# ------------------------------------------------------------------------------
uninstall_buttons() {
    echo ""
    echo "=== Uninstalling Button Controller for $TARGET_USER ==="

    local service_dir="$USER_HOME/.config/systemd/user"

    # Stop and disable user service
    if sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
        systemctl --user is-active --quiet buttons.service 2>/dev/null; then
        echo "  Stopping buttons service..."
        sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
            systemctl --user stop buttons.service || true
    fi
    if sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
        systemctl --user is-enabled --quiet buttons.service 2>/dev/null; then
        echo "  Disabling buttons service..."
        sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
            systemctl --user disable buttons.service || true
    fi

    # Remove files
    rm -f "$service_dir/buttons.service"
    rm -f "$USER_HOME/button-controller.py"

    # Reload user daemon
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
        systemctl --user daemon-reload 2>/dev/null || true

    echo "Button controller uninstalled."
}

# ------------------------------------------------------------------------------
# Module: Kiosk
# ------------------------------------------------------------------------------
uninstall_kiosk() {
    echo ""
    echo "=== Uninstalling Kiosk for $TARGET_USER ==="

    local service_dir="$USER_HOME/.config/systemd/user"

    # Try user-level service first (Wayland)
    if sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
        systemctl --user is-active --quiet kiosk.service 2>/dev/null; then
        echo "  Stopping kiosk user service..."
        sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
            systemctl --user stop kiosk.service || true
    fi
    if sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
        systemctl --user is-enabled --quiet kiosk.service 2>/dev/null; then
        echo "  Disabling kiosk user service..."
        sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
            systemctl --user disable kiosk.service || true
    fi
    rm -f "$service_dir/kiosk.service"

    # Remove kiosk script
    rm -f "$USER_HOME/start-kiosk.sh"

    # Reload daemons
    systemctl daemon-reload
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
        systemctl --user daemon-reload 2>/dev/null || true

    echo "Kiosk uninstalled."
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
echo "=== Gambit Scripts Uninstaller ==="

# Uninstall requested modules
$UNINSTALL_BUTTONS && uninstall_buttons
$UNINSTALL_KIOSK && uninstall_kiosk

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "=== Uninstallation Complete ==="
