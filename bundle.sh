#!/bin/bash
#
# Bundle scripts for deployment via base64 paste
# Copies base64-encoded tarball to clipboard (macOS)
#
# Usage: ./bundle.sh
#
# On Pi (via Viam shell):
#   echo 'PASTE_HERE' | base64 -d | tar xzf - -C /tmp
#   cd /tmp/safety-scripts
#   sudo ./install.sh --config --buttons --kiosk <username>
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Files to bundle (excludes Python scripts and tests)
FILES=(
    install.sh
    uninstall.sh
    config/
    buttons/
    rotate/
    kiosk/
)

echo "Bundling: ${FILES[*]}"

# Create temp dir with proper structure (macOS tar doesn't support --transform)
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/safety-scripts"
cp -r "${FILES[@]}" "$TMPDIR/safety-scripts/"

# Create tarball, base64 encode, copy to clipboard
tar czf - -C "$TMPDIR" safety-scripts | base64 | pbcopy

# Cleanup
rm -rf "$TMPDIR"

echo ""
echo "Copied to clipboard!"
echo ""
echo "On Pi (Viam shell):"
echo "  echo 'PASTE' | base64 -d | tar xzf - -C /tmp"
echo "  cd /tmp/safety-scripts"
echo "  sudo ./install.sh --config --buttons --kiosk <username>"
