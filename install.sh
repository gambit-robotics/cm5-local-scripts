#!/bin/bash
#
# Gambit Scripts Installer
# Installs safety monitoring services and optional user modules (buttons, rotate, kiosk)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/gambit/safety"
CONFIG_DIR="/etc/gambit"
SYSTEMD_DIR="/etc/systemd/system"

# Module flags (defaults)
INSTALL_SAFETY=true
INSTALL_BUTTONS=false
INSTALL_ROTATE=false
INSTALL_KIOSK=false
KIOSK_TYPE=""  # "wayland", "x11", or "" (auto-detect)

# User module arguments
TARGET_USER=""
DISPLAY_OUTPUT=""
TOUCH_DEVICE=""

# ------------------------------------------------------------------------------
# Help
# ------------------------------------------------------------------------------
show_help() {
    cat << 'EOF'
Gambit Scripts Installer

Usage: sudo ./install.sh [OPTIONS] [<username> [<display-output> [<touch-device>]]]

Modules:
  (default)         Install safety monitoring services only
  --buttons         Install I2C volume button controller
  --rotate          Install auto-rotate (requires display-output arg)
  --kiosk           Install Chromium kiosk (auto-detects display server)
  --kiosk-wayland   Install Wayland kiosk explicitly
  --kiosk-x11       Install X11 kiosk explicitly
  --all             Install all modules
  --no-safety       Skip safety services (use with other modules)

Arguments (required for user-level modules):
  <username>        Target user for user-level services
  <display-output>  Display output name for rotate (e.g., HDMI-A-1)
  <touch-device>    Optional touch device name for rotate

Examples:
  sudo ./install.sh                           # Safety only (backwards compatible)
  sudo ./install.sh --buttons pi              # Safety + buttons for user 'pi'
  sudo ./install.sh --kiosk pi                # Safety + kiosk (auto-detect)
  sudo ./install.sh --all pi HDMI-A-1         # All modules
  sudo ./install.sh --no-safety --buttons pi  # Buttons only, no safety

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
        --buttons) INSTALL_BUTTONS=true; shift ;;
        --rotate) INSTALL_ROTATE=true; shift ;;
        --kiosk) INSTALL_KIOSK=true; shift ;;
        --kiosk-wayland) INSTALL_KIOSK=true; KIOSK_TYPE="wayland"; shift ;;
        --kiosk-x11) INSTALL_KIOSK=true; KIOSK_TYPE="x11"; shift ;;
        --all) INSTALL_BUTTONS=true; INSTALL_ROTATE=true; INSTALL_KIOSK=true; shift ;;
        --no-safety) INSTALL_SAFETY=false; shift ;;
        -*)
            die "Unknown option: $1. Use --help for usage."
            ;;
        *)
            # Positional arguments: username, display-output, touch-device
            if [[ -z "$TARGET_USER" ]]; then
                TARGET_USER="$1"
            elif [[ -z "$DISPLAY_OUTPUT" ]]; then
                DISPLAY_OUTPUT="$1"
            elif [[ -z "$TOUCH_DEVICE" ]]; then
                TOUCH_DEVICE="$1"
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
if { $INSTALL_BUTTONS || $INSTALL_ROTATE || $INSTALL_KIOSK; } && [[ -z "$TARGET_USER" ]]; then
    die "Username required for --buttons, --rotate, or --kiosk. Use --help for usage."
fi

# Rotate requires display output
if $INSTALL_ROTATE && [[ -z "$DISPLAY_OUTPUT" ]]; then
    die "--rotate requires display output. Usage: $0 --rotate <username> <display-output>"
fi

# Validate user exists
if [[ -n "$TARGET_USER" ]]; then
    id "$TARGET_USER" &>/dev/null || die "User '$TARGET_USER' does not exist"
    USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    USER_ID=$(id -u "$TARGET_USER")
fi

# ------------------------------------------------------------------------------
# Module: Safety
# ------------------------------------------------------------------------------
install_safety() {
    echo ""
    echo "=== Installing Safety Monitoring ==="

    # Check for Python 3
    if ! command -v python3 &> /dev/null; then
        die "Python 3 is required but not installed"
    fi

    # Ensure pip is available
    if ! python3 -m pip --version &> /dev/null; then
        die "python3 -m pip is required but not installed"
    fi

    # Install lgpio for Pi 5 GPIO support
    if ! python3 -c "import lgpio" 2>/dev/null; then
        echo "Installing lgpio for Raspberry Pi 5 support..."
        apt-get install -y -qq python3-lgpio
    fi

    # Install Python dependencies
    echo "Installing Python dependencies..."
    PIP_ARGS="--quiet"
    if python3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)" 2>/dev/null; then
        if python3 -m pip --help 2>/dev/null | grep -q -- "--break-system-packages"; then
            PIP_ARGS="$PIP_ARGS --break-system-packages"
        else
            echo "Warning: Python 3.11+ detected but pip does not support --break-system-packages"
        fi
    fi

    python3 -m pip install $PIP_ARGS \
        adafruit-circuitpython-pct2075 \
        adafruit-circuitpython-ina219 \
        adafruit-blinka \
        pyyaml

    # Create directories
    echo "Creating directories..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$CONFIG_DIR"

    # Copy scripts
    echo "Installing scripts to $INSTALL_DIR..."
    cp "$SCRIPT_DIR/scripts/pct2075_safety.py" "$INSTALL_DIR/"
    cp "$SCRIPT_DIR/scripts/ina219_safety.py" "$INSTALL_DIR/"
    chmod +x "$INSTALL_DIR"/*.py

    # Copy config (don't overwrite existing)
    if [[ -f "$CONFIG_DIR/safety-config.yaml" ]]; then
        echo "Config already exists at $CONFIG_DIR/safety-config.yaml (not overwriting)"
        cp "$SCRIPT_DIR/config.yaml" "$CONFIG_DIR/safety-config.yaml.new"
    else
        echo "Installing config to $CONFIG_DIR/safety-config.yaml..."
        cp "$SCRIPT_DIR/config.yaml" "$CONFIG_DIR/safety-config.yaml"
    fi

    # Copy systemd units
    echo "Installing systemd service files..."
    cp "$SCRIPT_DIR/systemd/pct2075-safety.service" "$SYSTEMD_DIR/"
    cp "$SCRIPT_DIR/systemd/ina219-safety.service" "$SYSTEMD_DIR/"

    # Reload and enable
    systemctl daemon-reload
    for service in pct2075-safety ina219-safety; do
        echo "  Enabling $service..."
        systemctl enable "$service.service"
        systemctl start "$service.service"
    done

    echo "Safety monitoring installed."
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
# Module: Rotate
# ------------------------------------------------------------------------------
install_rotate() {
    echo ""
    echo "=== Installing Auto-Rotate for $TARGET_USER ==="
    if [[ -n "$TOUCH_DEVICE" ]]; then
        "$SCRIPT_DIR/rotate/setup-autorotate.sh" "$TARGET_USER" "$DISPLAY_OUTPUT" "$TOUCH_DEVICE"
    else
        "$SCRIPT_DIR/rotate/setup-autorotate.sh" "$TARGET_USER" "$DISPLAY_OUTPUT"
    fi
}

# ------------------------------------------------------------------------------
# Module: Kiosk
# ------------------------------------------------------------------------------
detect_display_server() {
    # Try to detect from user's session type
    local session_type=""
    session_type=$(sudo -u "$TARGET_USER" bash -c 'echo $XDG_SESSION_TYPE' 2>/dev/null || true)

    if [[ "$session_type" == "wayland" ]]; then
        echo "wayland"
        return
    elif [[ "$session_type" == "x11" ]]; then
        echo "x11"
        return
    fi

    # Fallback: check for wayland tools (Bookworm default is wayland)
    if command -v wlr-randr &>/dev/null || command -v labwc &>/dev/null; then
        echo "wayland"
    else
        echo "x11"
    fi
}

install_kiosk() {
    local display_type="${KIOSK_TYPE:-$(detect_display_server)}"
    echo ""
    echo "=== Installing Kiosk ($display_type) for $TARGET_USER ==="

    if [[ "$display_type" == "wayland" ]]; then
        "$SCRIPT_DIR/kiosk/setup-kiosk-wayland.sh" "$TARGET_USER"
    else
        "$SCRIPT_DIR/kiosk/setup-kiosk-x11.sh" "$TARGET_USER"
    fi
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
$INSTALL_SAFETY && install_safety
$INSTALL_BUTTONS && install_buttons
$INSTALL_ROTATE && install_rotate
$INSTALL_KIOSK && install_kiosk

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "=== Installation Complete ==="
echo ""

if $INSTALL_SAFETY; then
    echo "Safety services:"
    for service in pct2075-safety ina219-safety; do
        status=$(systemctl is-active "$service.service" 2>/dev/null || echo "unknown")
        echo "  - $service: $status"
    done
    echo ""
    echo "Configuration: $CONFIG_DIR/safety-config.yaml"
    echo "View logs: journalctl -u pct2075-safety -f"
fi

if $INSTALL_BUTTONS || $INSTALL_ROTATE || $INSTALL_KIOSK; then
    echo ""
    echo "User services installed for $TARGET_USER."
    echo "Commands (run as $TARGET_USER):"
    echo "  systemctl --user status <service>"
    echo "  journalctl --user -u <service> -f"
fi

echo ""
echo "Reboot recommended for all changes to take effect."
