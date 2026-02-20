#!/bin/bash
#
# Bundle scripts for deployment via base64 paste
# Copies base64-encoded tarball to clipboard (macOS)
#
# Usage: ./bundle.sh [--quiet]
#

set -e

QUIET=false
[[ "${1:-}" == "--quiet" ]] && QUIET=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Files/dirs to bundle (excludes Python scripts and tests)
DIRS=(config buttons kiosk plymouth)
FILES=(install.sh uninstall.sh Makefile)

$QUIET || echo "Bundling: ${FILES[*]} ${DIRS[*]}"

# Create temp dir with proper structure
TMPDIR=$(mktemp -d)
mkdir -p "$TMPDIR/cm5-local-scripts"

# Copy files
for f in "${FILES[@]}"; do
    cp "$f" "$TMPDIR/cm5-local-scripts/"
done

# Copy directories preserving structure
for d in "${DIRS[@]}"; do
    cp -r "$d" "$TMPDIR/cm5-local-scripts/"
done

# Make scripts executable
find "$TMPDIR/cm5-local-scripts" -name "*.sh" -exec chmod +x {} \;

# Create tarball without macOS metadata, base64 encode, copy to clipboard
COPYFILE_DISABLE=1 tar czf - -C "$TMPDIR" cm5-local-scripts | base64 | pbcopy

# Cleanup
rm -rf "$TMPDIR"

if $QUIET; then
    echo "Bundle copied to clipboard"
else
    echo ""
    echo "Bundle copied to clipboard!"
    echo ""
    echo "Next: Run 'make deploy' to upload, or manually:"
    echo "  pbpaste > /tmp/bundle.b64"
    echo "  curl -s -F 'content=<-' https://dpaste.com/api/ < /tmp/bundle.b64"
fi
