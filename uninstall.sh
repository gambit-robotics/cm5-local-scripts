#!/bin/bash
#
# Gambit Scripts Uninstaller
# Removes safety monitoring services and optional user modules (buttons, rotate, kiosk)
#

set -e

INSTALL_DIR="/opt/gambit/safety"
CONFIG_DIR="/etc/gambit"
SYSTEMD_DIR="/etc/systemd/system"

# Module flags (defaults)
UNINSTALL_SAFETY=true
UNINSTALL_BUTTONS=false
UNINSTALL_ROTATE=false
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
  (default)         Uninstall safety monitoring services only
  --buttons         Uninstall I2C volume button controller
  --rotate          Uninstall auto-rotate (DEPRECATED)
  --kiosk           Uninstall Chromium kiosk
  --all             Uninstall all modules
  --no-safety       Skip safety services (use with other modules)

Arguments (required for user-level modules):
  <username>        Target user whose services to remove

Examples:
  sudo ./uninstall.sh                           # Safety only
  sudo ./uninstall.sh --buttons pi              # Safety + buttons
  sudo ./uninstall.sh --all pi                  # All modules
  sudo ./uninstall.sh --no-safety --kiosk pi    # Kiosk only

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
        --rotate) UNINSTALL_ROTATE=true; shift ;;
        --kiosk) UNINSTALL_KIOSK=true; shift ;;
        --all) UNINSTALL_BUTTONS=true; UNINSTALL_ROTATE=true; UNINSTALL_KIOSK=true; shift ;;
        --no-safety) UNINSTALL_SAFETY=false; shift ;;
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
if { $UNINSTALL_BUTTONS || $UNINSTALL_ROTATE || $UNINSTALL_KIOSK; } && [[ -z "$TARGET_USER" ]]; then
    die "Username required for --buttons, --rotate, or --kiosk. Use --help for usage."
fi

# Validate user exists (for user modules)
if [[ -n "$TARGET_USER" ]]; then
    id "$TARGET_USER" &>/dev/null || die "User '$TARGET_USER' does not exist"
    USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    USER_ID=$(id -u "$TARGET_USER")
fi

# ------------------------------------------------------------------------------
# Module: Safety
# ------------------------------------------------------------------------------
uninstall_safety() {
    echo ""
    echo "=== Uninstalling Safety Monitoring ==="

    # Stop and disable services
    for service in pct2075-safety ina219-safety; do
        if systemctl is-active --quiet "$service.service" 2>/dev/null; then
            echo "  Stopping $service..."
            systemctl stop "$service.service" || true
        fi
        if systemctl is-enabled --quiet "$service.service" 2>/dev/null; then
            echo "  Disabling $service..."
            systemctl disable "$service.service" || true
        fi
    done

    # Remove systemd units
    echo "Removing systemd service files..."
    rm -f "$SYSTEMD_DIR/pct2075-safety.service"
    rm -f "$SYSTEMD_DIR/ina219-safety.service"

    # Reload systemd
    systemctl daemon-reload

    # Remove scripts
    echo "Removing scripts from $INSTALL_DIR..."
    rm -f "$INSTALL_DIR/pct2075_safety.py"
    rm -f "$INSTALL_DIR/ina219_safety.py"

    # Remove install directory if empty
    if [[ -d "$INSTALL_DIR" ]] && [[ -z "$(ls -A "$INSTALL_DIR")" ]]; then
        rmdir "$INSTALL_DIR"
        if [[ -d "/opt/gambit" ]] && [[ -z "$(ls -A /opt/gambit)" ]]; then
            rmdir "/opt/gambit"
        fi
    fi

    # Remove config
    echo "Removing configuration..."
    rm -f "$CONFIG_DIR/safety-config.yaml"
    rm -f "$CONFIG_DIR/safety-config.yaml.new"

    if [[ -d "$CONFIG_DIR" ]] && [[ -z "$(ls -A "$CONFIG_DIR")" ]]; then
        rmdir "$CONFIG_DIR"
    fi

    echo "Safety monitoring uninstalled."
}

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
# Module: Rotate
# ------------------------------------------------------------------------------
uninstall_rotate() {
    echo ""
    echo "=== Uninstalling Auto-Rotate for $TARGET_USER ==="
    echo "Note: Auto-rotate is deprecated. Use https://github.com/gambit-robotics/viam-accelerometer instead."

    local service_dir="$USER_HOME/.config/systemd/user"

    # Stop and disable user service
    if sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
        systemctl --user is-active --quiet autorotate.service 2>/dev/null; then
        echo "  Stopping autorotate service..."
        sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
            systemctl --user stop autorotate.service || true
    fi
    if sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
        systemctl --user is-enabled --quiet autorotate.service 2>/dev/null; then
        echo "  Disabling autorotate service..."
        sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
            systemctl --user disable autorotate.service || true
    fi

    # Remove files
    rm -f "$service_dir/autorotate.service"
    rm -f "$USER_HOME/rotate-screen.py"

    # Remove udev rule and sudoers
    rm -f "/etc/udev/rules.d/99-touch-rotation.rules"
    rm -f "/etc/sudoers.d/autorotate"
    udevadm control --reload-rules 2>/dev/null || true

    # Reload user daemon
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$USER_ID" \
        systemctl --user daemon-reload 2>/dev/null || true

    echo "Auto-rotate uninstalled."
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
$UNINSTALL_SAFETY && uninstall_safety
$UNINSTALL_BUTTONS && uninstall_buttons
$UNINSTALL_ROTATE && uninstall_rotate
$UNINSTALL_KIOSK && uninstall_kiosk

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "=== Uninstallation Complete ==="
echo ""
echo "Note: Python packages (adafruit-*) were NOT removed."
echo "To remove them manually:"
echo "  pip3 uninstall adafruit-circuitpython-pct2075 adafruit-circuitpython-ina219 adafruit-circuitpython-lis3dh"
