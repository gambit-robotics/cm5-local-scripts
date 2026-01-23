#!/bin/bash
#
# Bundle scripts for deployment via base64 paste
# Copies base64-encoded tarball to clipboard (macOS)
#
# Usage: ./bundle.sh
#
# Then upload to dpaste:
#   pbpaste > /tmp/bundle.b64
#   curl -s -F 'content=<-' https://dpaste.com/api/ < /tmp/bundle.b64
#
# On Pi (via Viam shell):
#   curl -sL <DPASTE_URL>.txt | base64 -d | tar xzf - -C /tmp
#   cd /tmp/safety-scripts
#   sudo ./install.sh --no-safety --config --buttons --rotate --kiosk <username> <display>
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Files/dirs to bundle (excludes Python scripts and tests)
DIRS=(config buttons rotate kiosk)
FILES=(install.sh uninstall.sh)

echo "Bundling: ${FILES[*]} ${DIRS[*]}"

# Create temp dir with proper structure
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/safety-scripts"

# Copy files
for f in "${FILES[@]}"; do
    cp "$f" "$TMPDIR/safety-scripts/"
done

# Copy directories preserving structure
for d in "${DIRS[@]}"; do
    cp -r "$d" "$TMPDIR/safety-scripts/"
done

# Make scripts executable
find "$TMPDIR/safety-scripts" -name "*.sh" -exec chmod +x {} \;

# Create tarball without macOS metadata, base64 encode, copy to clipboard
COPYFILE_DISABLE=1 tar czf - -C "$TMPDIR" safety-scripts | base64 | pbcopy

# Cleanup
rm -rf "$TMPDIR"

echo ""
echo "Copied to clipboard!"
echo ""
echo "Upload to dpaste:"
echo "  pbpaste > /tmp/bundle.b64"
echo "  curl -s -F 'content=<-' https://dpaste.com/api/ < /tmp/bundle.b64"
echo ""
echo "On Pi (Viam shell):"
echo "  curl -sL <URL>.txt | base64 -d | tar xzf - -C /tmp"
echo "  cd /tmp/safety-scripts"
echo "  sudo ./install.sh --no-safety --config --buttons --rotate --kiosk <user> <display>"
