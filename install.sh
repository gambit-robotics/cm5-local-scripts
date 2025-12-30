#!/bin/bash
#
# Gambit Safety Scripts Installer
# Installs PCT2075, MCP9601, and INA219 safety monitoring services
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/gambit/safety"
CONFIG_DIR="/etc/gambit"
SYSTEMD_DIR="/etc/systemd/system"

SERVICES="pct2075-safety mcp9601-safety ina219-safety"

echo "=== Gambit Safety Scripts Installer ==="
echo ""

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

# Check for Python 3
if ! command -v python3 &> /dev/null; then
    echo "Error: Python 3 is required but not installed"
    exit 1
fi

# Ensure pip is available for the same interpreter
if ! python3 -m pip --version &> /dev/null; then
    echo "Error: python3 -m pip is required but not installed"
    exit 1
fi

# Install lgpio for Pi 5 GPIO support
if ! python3 -c "import lgpio" 2>/dev/null; then
    echo "Installing lgpio for Raspberry Pi 5 support..."
    apt-get update -qq
    apt-get install -y -qq python3-lgpio
fi

# Install Python dependencies
# Use --break-system-packages for Python 3.11+ (PEP 668) when supported by pip
echo "Installing Python dependencies..."
PIP_ARGS="--quiet"
if python3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)" 2>/dev/null; then
    if python3 -m pip --help 2>/dev/null | grep -q -- "--break-system-packages"; then
        PIP_ARGS="$PIP_ARGS --break-system-packages"
    else
        echo "Warning: Python 3.11+ detected but pip does not support --break-system-packages; install may fail under PEP 668 constraints."
    fi
fi

python3 -m pip install $PIP_ARGS \
    adafruit-circuitpython-pct2075 \
    adafruit-circuitpython-mcp9600 \
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
cp "$SCRIPT_DIR/scripts/mcp9601_safety.py" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/scripts/ina219_safety.py" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR"/*.py

# Copy config (don't overwrite existing)
if [[ -f "$CONFIG_DIR/safety-config.yaml" ]]; then
    echo "Config file already exists at $CONFIG_DIR/safety-config.yaml (not overwriting)"
    echo "New config saved to $CONFIG_DIR/safety-config.yaml.new for reference"
    cp "$SCRIPT_DIR/config.yaml" "$CONFIG_DIR/safety-config.yaml.new"
else
    echo "Installing config to $CONFIG_DIR/safety-config.yaml..."
    cp "$SCRIPT_DIR/config.yaml" "$CONFIG_DIR/safety-config.yaml"
fi

# Copy systemd units
echo "Installing systemd service files..."
cp "$SCRIPT_DIR/systemd/pct2075-safety.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/systemd/mcp9601-safety.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/systemd/ina219-safety.service" "$SYSTEMD_DIR/"

# Reload systemd
echo "Reloading systemd daemon..."
systemctl daemon-reload

# Enable and start services
echo "Enabling and starting services..."
for service in $SERVICES; do
    echo "  - $service"
    systemctl enable "$service.service"
    systemctl start "$service.service"
done

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Services installed and running:"
for service in $SERVICES; do
    status=$(systemctl is-active "$service.service" 2>/dev/null || echo "unknown")
    echo "  - $service: $status"
done
echo ""
echo "Configuration: $CONFIG_DIR/safety-config.yaml"
echo "Scripts: $INSTALL_DIR/"
echo ""
echo "View logs with: journalctl -u <service-name> -f"
echo "Example: journalctl -u pct2075-safety -f"
