#!/bin/bash
#
# Gambit Scripts Installer
# Installs user modules (buttons, kiosk, plymouth, config)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Module flags (defaults)
INSTALL_CONFIG=false
INSTALL_BUTTONS=false
INSTALL_KIOSK=false
INSTALL_PLYMOUTH=false
KIOSK_TYPE=""  # "wayland" or "" (auto-detect)

# User module arguments
TARGET_USER=""

# ------------------------------------------------------------------------------
# Help
# ------------------------------------------------------------------------------
show_help() {
    cat << 'EOF'
Gambit Scripts Installer

Usage: sudo ./install.sh [OPTIONS] [<username>]

Modules:
  --config          Install boot config & audio config (requires reboot)
  --buttons         Install I2C volume button controller
  --kiosk           Install Chromium kiosk
  --kiosk-wayland   Install Wayland kiosk explicitly
  --plymouth        Install custom boot splash screen
  --all             Install all modules (including config)

Arguments (required for user-level modules):
  <username>        Target user for user-level services

Examples:
  sudo ./install.sh --buttons pi              # Buttons for user 'pi'
  sudo ./install.sh --kiosk pi                # Kiosk (auto-detect)
  sudo ./install.sh --all pi                  # All modules
  sudo ./install.sh --config                  # Config only

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
        --config) INSTALL_CONFIG=true; shift ;;
        --buttons) INSTALL_BUTTONS=true; shift ;;
        --kiosk) INSTALL_KIOSK=true; shift ;;
        --kiosk-wayland) INSTALL_KIOSK=true; KIOSK_TYPE="wayland"; shift ;;
        --plymouth) INSTALL_PLYMOUTH=true; shift ;;
        --all) INSTALL_CONFIG=true; INSTALL_BUTTONS=true; INSTALL_KIOSK=true; INSTALL_PLYMOUTH=true; shift ;;
        -*)
            die "Unknown option: $1. Use --help for usage."
            ;;
        *)
            # Positional arguments: username
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
if { $INSTALL_BUTTONS || $INSTALL_KIOSK; } && [[ -z "$TARGET_USER" ]]; then
    die "Username required for --buttons or --kiosk. Use --help for usage."
fi

# Validate user exists
if [[ -n "$TARGET_USER" ]]; then
    id "$TARGET_USER" &>/dev/null || die "User '$TARGET_USER' does not exist"
    USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    USER_ID=$(id -u "$TARGET_USER")
fi

# ------------------------------------------------------------------------------
# Module: Config
# ------------------------------------------------------------------------------
install_config() {
    echo ""
    echo "=== Installing System Configuration ==="

    # Boot config
    if [[ -f "$SCRIPT_DIR/config/config.txt" ]]; then
        echo "Installing boot config to /boot/firmware/config.txt..."
        if [[ -f /boot/firmware/config.txt ]]; then
            cp /boot/firmware/config.txt /boot/firmware/config.txt.backup
            echo "  Backed up existing config to /boot/firmware/config.txt.backup"
        fi
        cp "$SCRIPT_DIR/config/config.txt" /boot/firmware/config.txt
    else
        echo "Warning: config/config.txt not found, skipping boot config"
    fi

    # Audio config
    if [[ -f "$SCRIPT_DIR/config/asound.conf" ]]; then
        echo "Installing audio config to /etc/asound.conf..."
        if [[ -f /etc/asound.conf ]]; then
            cp /etc/asound.conf /etc/asound.conf.backup
            echo "  Backed up existing config to /etc/asound.conf.backup"
        fi
        cp "$SCRIPT_DIR/config/asound.conf" /etc/asound.conf
    else
        echo "Warning: config/asound.conf not found, skipping audio config"
    fi

    echo "System configuration installed."
}

# ------------------------------------------------------------------------------
# Module: Buttons
# ------------------------------------------------------------------------------
install_buttons() {
    echo ""
    echo "=== Installing Button Controller for $TARGET_USER ==="
    "$SCRIPT_DIR/buttons/setup-buttons.sh" "$TARGET_USER"
}

# ------------------------------------------------------------------------------
# Module: Kiosk
# ------------------------------------------------------------------------------
detect_display_server() {
    echo "wayland"
}

install_kiosk() {
    local display_type="${KIOSK_TYPE:-$(detect_display_server)}"
    echo ""
    echo "=== Installing Kiosk ($display_type) for $TARGET_USER ==="

    "$SCRIPT_DIR/kiosk/setup-kiosk-wayland.sh" "$TARGET_USER"
}

# ------------------------------------------------------------------------------
# Module: Plymouth
# ------------------------------------------------------------------------------
install_plymouth() {
    echo ""
    echo "=== Installing Plymouth Boot Splash ==="
    "$SCRIPT_DIR/plymouth/setup-bootsplash.sh"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
echo "=== Gambit Scripts Installer ==="

# Single apt-get update for all modules
echo ""
echo "Updating package lists..."
apt-get update -qq

# Export flag so standalone scripts skip their apt-get update
export SKIP_APT_UPDATE=1

# Install requested modules
$INSTALL_CONFIG && install_config
$INSTALL_BUTTONS && install_buttons
$INSTALL_KIOSK && install_kiosk
$INSTALL_PLYMOUTH && install_plymouth

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "=== Installation Complete ==="
echo ""

if $INSTALL_CONFIG; then
    echo "System config installed:"
    echo "  - /boot/firmware/config.txt"
    echo "  - /etc/asound.conf"
    echo ""
fi

if $INSTALL_BUTTONS || $INSTALL_KIOSK; then
    echo "User services installed for $TARGET_USER."
    echo "Commands (run as $TARGET_USER):"
    echo "  systemctl --user status <service>"
    echo "  journalctl --user -u <service> -f"
fi

if $INSTALL_PLYMOUTH; then
    echo ""
    echo "Plymouth boot splash installed."
    echo "  Theme: gambit"
    echo "  Test: sudo plymouthd --debug --tty=/dev/tty1 && sudo plymouth show-splash"
fi

echo ""
echo "Reboot recommended for all changes to take effect."
