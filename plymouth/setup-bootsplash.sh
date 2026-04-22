#!/bin/bash
# Plymouth Boot Splash Setup Script for Raspberry Pi with Debian Trixie
# Creates a custom boot splash screen using Plymouth

set -e

# Get script directory for finding default splash image
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

THEME_NAME="${1:-gambit}"
SPLASH_IMAGE="${2:-${SCRIPT_DIR}/SplashLoading.png}"
SHUTDOWN_IMAGE="${3:-${SCRIPT_DIR}/SplashShutdown.png}"
DOT_IMAGE="${SCRIPT_DIR}/dot.png"
THEME_DIR="/usr/share/plymouth/themes/${THEME_NAME}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }

usage() {
    echo "Usage: $0 [theme_name] [path_to_splash_image.png]"
    echo ""
    echo "Examples:"
    echo "  $0                              # Uses 'gambit' theme and splash.png from script dir"
    echo "  $0 gambit                       # Uses splash.png from script dir"
    echo "  $0 mybrand /home/pi/logo.png    # Custom theme and image"
    echo ""
    echo "Defaults: theme='gambit', image='splash.png' (in same directory as script)"
    exit 1
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root (use sudo)"
    exit 1
fi

# Check for splash image
if [[ ! -f "$SPLASH_IMAGE" ]]; then
    print_error "Splash image not found: $SPLASH_IMAGE"
    echo ""
    usage
fi

# Check for loading-dot sprite (required by the animated splash, GMBT-156)
if [[ ! -f "$DOT_IMAGE" ]]; then
    print_error "Dot image not found: $DOT_IMAGE"
    exit 1
fi

echo "================================================"
echo "  Plymouth Boot Splash Setup"
echo "  Theme: ${THEME_NAME}"
echo "  Image: ${SPLASH_IMAGE}"
echo "================================================"
echo ""

# Step 1: Install Plymouth
print_status "Installing Plymouth and themes..."
apt-get update -qq
apt-get install -y plymouth plymouth-themes

# Step 2: Create theme directory
print_status "Creating theme directory: ${THEME_DIR}"
mkdir -p "${THEME_DIR}"

# Step 3: Copy splash images
print_status "Copying splash images..."
cp "${SPLASH_IMAGE}" "${THEME_DIR}/splash.png"
if [[ -f "$SHUTDOWN_IMAGE" ]]; then
    cp "${SHUTDOWN_IMAGE}" "${THEME_DIR}/shutdown-splash.png"
    print_status "Shutdown splash image copied."
else
    print_warning "No shutdown splash found at: $SHUTDOWN_IMAGE"
    print_warning "Shutdown will reuse the boot splash image."
    cp "${SPLASH_IMAGE}" "${THEME_DIR}/shutdown-splash.png"
fi
# Loading-dot sprite used by the animated boot splash (GMBT-156)
cp "${DOT_IMAGE}" "${THEME_DIR}/dot.png"

# Step 4: Create the theme script
print_status "Creating theme script..."
cat > "${THEME_DIR}/${THEME_NAME}.script" << 'EOF'
# Plymouth theme script - shows boot or shutdown image based on mode

status = Plymouth.GetMode();
is_shutdown = (status == "shutdown" || status == "reboot");

if (is_shutdown) {
    wallpaper_image = Image("shutdown-splash.png");
} else {
    wallpaper_image = Image("splash.png");
}

screen_width = Window.GetWidth();
screen_height = Window.GetHeight();
resized_wallpaper_image = wallpaper_image.Scale(screen_width, screen_height);
wallpaper_sprite = Sprite(resized_wallpaper_image);
wallpaper_sprite.SetZ(-100);

# Loading-dot animation (boot only) — liveness indicator so users can see the
# device is actively booting and not frozen on a static logo (GMBT-156).
if (!is_shutdown) {
    dot_image = Image("dot.png");
    dot_w = dot_image.GetWidth();
    dot_h = dot_image.GetHeight();
    dot_gap = dot_w / 2;
    total_w = 3 * dot_w + 2 * dot_gap;
    dot_y = screen_height - (dot_h * 2);
    dot_x0 = (screen_width - total_w) / 2;

    dot0 = Sprite(dot_image);
    dot0.SetX(dot_x0);
    dot0.SetY(dot_y);
    dot0.SetZ(10);
    dot0.SetOpacity(0.3);

    dot1 = Sprite(dot_image);
    dot1.SetX(dot_x0 + (dot_w + dot_gap));
    dot1.SetY(dot_y);
    dot1.SetZ(10);
    dot1.SetOpacity(0.3);

    dot2 = Sprite(dot_image);
    dot2.SetX(dot_x0 + 2 * (dot_w + dot_gap));
    dot2.SetY(dot_y);
    dot2.SetZ(10);
    dot2.SetOpacity(0.3);
}

# Hide password prompt styling
fun password_dialogue_setup(message, bullets) {
    global.password_dialogue = 1;
}

fun password_dialogue_opacity(opacity) {
}

fun display_password(prompt, bullets) {
}

# Hide messages
fun message_callback(text) {
}

# Triangle-wave opacity per dot: ramp 0.3 -> 1.0 over 30 frames, back down over 30.
# Each dot is offset by 20 frames so they chase in a wave.
fun dot_opacity(phase, offset) {
    local = phase + offset;
    while (local >= 60) {
        local = local - 60;
    }
    tri = local;
    if (tri > 30) {
        tri = 60 - tri;
    }
    return 0.3 + 0.7 * (tri / 30);
}

phase = 0;
Plymouth.SetRefreshFunction(fun() {
    if (!is_shutdown) {
        phase = phase + 1;
        if (phase >= 60) {
            phase = 0;
        }
        dot0.SetOpacity(dot_opacity(phase, 0));
        dot1.SetOpacity(dot_opacity(phase, 20));
        dot2.SetOpacity(dot_opacity(phase, 40));
    }
});
EOF

# Step 5: Create the theme file
print_status "Creating theme configuration..."
cat > "${THEME_DIR}/${THEME_NAME}.plymouth" << EOF
[Plymouth Theme]
Name=${THEME_NAME}
Description=Custom ${THEME_NAME} boot splash
ModuleName=script

[script]
ImageDir=${THEME_DIR}
ScriptFile=${THEME_DIR}/${THEME_NAME}.script
EOF

# Step 6: Set the default theme
print_status "Setting ${THEME_NAME} as default Plymouth theme..."
plymouth-set-default-theme "${THEME_NAME}"

# Step 7: Update initramfs
print_status "Updating initramfs (this may take a moment)..."
update-initramfs -u

# Step 8: Update cmdline.txt for splash
CMDLINE_FILE="/boot/firmware/cmdline.txt"
if [[ -f "$CMDLINE_FILE" ]]; then
    print_status "Updating boot parameters..."

    # Backup original
    cp "${CMDLINE_FILE}" "${CMDLINE_FILE}.backup"

    # Read current cmdline
    CMDLINE=$(cat "$CMDLINE_FILE")

    # Add splash parameters if not present
    if [[ ! "$CMDLINE" =~ "splash" ]]; then
        CMDLINE="${CMDLINE} splash"
    fi
    if [[ ! "$CMDLINE" =~ "quiet" ]]; then
        CMDLINE="${CMDLINE} quiet"
    fi
    if [[ ! "$CMDLINE" =~ "loglevel=" ]]; then
        CMDLINE="${CMDLINE} loglevel=0"
    fi
    if [[ ! "$CMDLINE" =~ "vt.global_cursor_default=" ]]; then
        CMDLINE="${CMDLINE} vt.global_cursor_default=0"
    fi

    # Write updated cmdline
    echo "$CMDLINE" > "$CMDLINE_FILE"
    print_status "Boot parameters updated. Backup saved to ${CMDLINE_FILE}.backup"
else
    print_warning "Could not find ${CMDLINE_FILE}"
    print_warning "Please manually add 'splash quiet loglevel=0 vt.global_cursor_default=0' to your boot parameters"
fi

echo ""
echo "================================================"
print_status "Plymouth boot splash setup complete!"
echo "================================================"
echo ""
echo "Theme installed to: ${THEME_DIR}"
echo ""
echo "To test without rebooting:"
echo "  sudo plymouthd --debug --tty=/dev/tty1"
echo "  sudo plymouth show-splash"
echo "  sleep 5"
echo "  sudo plymouth quit"

# plymouth-quit.service must stay unmasked (lightdm has After= and Conflicts= on it)
# plymouth-quit-wait.service must be masked: it blocks multi-user.target for ~85s due to
# a circular dependency (lightdm needs multi-user.target, but plymouth-quit needs lightdm)
print_status "Configuring Plymouth service ordering..."
systemctl unmask plymouth-quit.service 2>/dev/null || true
systemctl mask plymouth-quit-wait.service 2>/dev/null || true

# Step 10: Create shutdown splash service
print_status "Setting up shutdown splash service..."
cat > /etc/systemd/system/plymouth-shutdown-splash.service << 'SVCEOF'
[Unit]
Description=Show Plymouth Splash on Shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target
After=final.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/plymouthd --mode=shutdown --tty=/dev/tty1
ExecStart=/usr/bin/plymouth show-splash

[Install]
WantedBy=shutdown.target reboot.target halt.target
SVCEOF

systemctl daemon-reload
systemctl enable plymouth-shutdown-splash.service

echo ""
echo "Reboot to see your new boot splash:"
echo "  sudo reboot"
echo ""
