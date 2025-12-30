#!/bin/bash
#
# Gambit Safety Scripts Uninstaller
# Removes PCT2075, MCP9601, and INA219 safety monitoring services
#

set -e

INSTALL_DIR="/opt/gambit/safety"
CONFIG_DIR="/etc/gambit"
SYSTEMD_DIR="/etc/systemd/system"

SERVICES="pct2075-safety mcp9601-safety ina219-safety"

echo "=== Gambit Safety Scripts Uninstaller ==="
echo ""

# Check for root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

# Stop and disable services
echo "Stopping and disabling services..."
for service in $SERVICES; do
    if systemctl is-active --quiet "$service.service" 2>/dev/null; then
        echo "  - Stopping $service..."
        systemctl stop "$service.service" || true
    fi
    if systemctl is-enabled --quiet "$service.service" 2>/dev/null; then
        echo "  - Disabling $service..."
        systemctl disable "$service.service" || true
    fi
done

# Remove systemd units
echo "Removing systemd service files..."
rm -f "$SYSTEMD_DIR/pct2075-safety.service"
rm -f "$SYSTEMD_DIR/mcp9601-safety.service"
rm -f "$SYSTEMD_DIR/ina219-safety.service"

# Reload systemd
echo "Reloading systemd daemon..."
systemctl daemon-reload

# Remove scripts
echo "Removing scripts from $INSTALL_DIR..."
rm -f "$INSTALL_DIR/pct2075_safety.py"
rm -f "$INSTALL_DIR/mcp9601_safety.py"
rm -f "$INSTALL_DIR/ina219_safety.py"

# Remove install directory if empty
if [[ -d "$INSTALL_DIR" ]] && [[ -z "$(ls -A "$INSTALL_DIR")" ]]; then
    rmdir "$INSTALL_DIR"
    # Also remove parent if empty
    if [[ -d "/opt/gambit" ]] && [[ -z "$(ls -A /opt/gambit)" ]]; then
        rmdir "/opt/gambit"
    fi
fi

# Remove config
echo "Removing configuration..."
rm -f "$CONFIG_DIR/safety-config.yaml"
rm -f "$CONFIG_DIR/safety-config.yaml.new"

# Remove config directory if empty
if [[ -d "$CONFIG_DIR" ]] && [[ -z "$(ls -A "$CONFIG_DIR")" ]]; then
    rmdir "$CONFIG_DIR"
fi

echo ""
echo "=== Uninstallation Complete ==="
echo ""
echo "Note: Python packages (adafruit-*) were NOT removed."
echo "To remove them manually: pip3 uninstall adafruit-circuitpython-pct2075 adafruit-circuitpython-mcp9600 adafruit-circuitpython-ina219"
