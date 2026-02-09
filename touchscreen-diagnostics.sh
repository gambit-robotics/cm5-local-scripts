#!/bin/bash
# Touchscreen & Wayland/labwc Diagnostics
# Run on both machines and diff output (Gambit CM5)
# Usage: sudo ./touchscreen-diagnostics.sh

OUTPUT_FILE=~/touchscreen-diag-$(hostname).txt

# --- Auto-detect the labwc user ---
LABWC_PID=$(pgrep -x labwc | head -1)
if [[ -n "$LABWC_PID" ]]; then
    LABWC_USER=$(ps -o user= -p "$LABWC_PID" | tr -d ' ')
    LABWC_UID=$(id -u "$LABWC_USER")
    LABWC_HOME=$(getent passwd "$LABWC_USER" | cut -d: -f6)
    LABWC_RUNTIME="/run/user/$LABWC_UID"
else
    LABWC_USER=""
    LABWC_UID=""
    LABWC_HOME=""
    LABWC_RUNTIME=""
fi

# Helper: run a command as the labwc user with Wayland env
run_as_labwc() {
    if [[ -n "$LABWC_USER" ]]; then
        sudo -u "$LABWC_USER" \
            WAYLAND_DISPLAY=wayland-0 \
            XDG_RUNTIME_DIR="$LABWC_RUNTIME" \
            "$@" 2>&1
    else
        echo "(labwc not running, skipped)"
    fi
}

{
echo "=== HOSTNAME ==="
hostname

echo -e "\n=== DATE ==="
date

echo -e "\n=== KERNEL ==="
uname -r

# ---------- Package Versions ----------

echo -e "\n=== PACKAGE VERSIONS ==="
dpkg -l 2>/dev/null | grep -E "labwc|libinput|autotouch|wlroots|chromium|xwayland|wayvnc" || echo "(none matched)"

# ---------- Wayland / Display ----------

echo -e "\n=== LABWC USER ==="
if [[ -n "$LABWC_USER" ]]; then
    echo "user=$LABWC_USER  uid=$LABWC_UID  pid=$LABWC_PID"
else
    echo "(labwc not running)"
fi

echo -e "\n=== WLR-RANDR ==="
run_as_labwc wlr-randr

echo -e "\n=== DISPLAY ENV ==="
echo "DISPLAY=$DISPLAY"
echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"

# ---------- Input Devices ----------

echo -e "\n=== LIBINPUT DEVICES ==="
sudo libinput list-devices 2>/dev/null

echo -e "\n=== /proc/bus/input/devices (touch) ==="
grep -A 6 -i touch /proc/bus/input/devices 2>/dev/null || echo "(no touch device found)"

echo -e "\n=== RELEVANT KERNEL MODULES ==="
lsmod | grep -E "(touch|hid|input|goodix|elan|wacom)" || echo "(none loaded)"

# ---------- Touch Device Access ----------

echo -e "\n=== TOUCH EVENT DEVICE ==="
TOUCH_EVENT=$(grep -B 2 -A 6 -i touch /proc/bus/input/devices 2>/dev/null \
    | grep -oP 'event\d+' | head -1)
if [[ -n "$TOUCH_EVENT" ]]; then
    echo "Detected: /dev/input/$TOUCH_EVENT"

    echo -e "\n=== LSOF TOUCH DEVICE ==="
    lsof "/dev/input/$TOUCH_EVENT" 2>/dev/null || echo "(no open handles)"

    echo -e "\n=== FUSER TOUCH DEVICE ==="
    fuser -v "/dev/input/$TOUCH_EVENT" 2>&1 || echo "(not in use)"

    echo -e "\n=== GETFACL TOUCH DEVICE ==="
    getfacl "/dev/input/$TOUCH_EVENT" 2>/dev/null || ls -la "/dev/input/$TOUCH_EVENT"

    if [[ -n "$LABWC_PID" ]]; then
        echo -e "\n=== LABWC FD -> INPUT ==="
        ls -la /proc/"$LABWC_PID"/fd 2>/dev/null | grep input || echo "(no input fds)"
    fi
else
    echo "(could not detect touch event device)"
fi

# ---------- Touch <-> labwc Config Cross-Check ----------
# IMPORTANT: An explicit <touch deviceName="..."> entry in the system rc.xml that
# matches the ACTUAL touch device name can BREAK touch input. labwc auto-detection
# works correctly without it. This was the root cause of TP2-RPi-CM5 touch failure
# (Feb 2026). The system config should only contain entries for OTHER bus addresses
# (4-, 6-, 10-, 11-) as fallbacks, NOT the real device (typically 0-0038).

echo -e "\n=== TOUCH DEVICE vs LABWC CONFIG CROSS-CHECK ==="
if [[ -n "$TOUCH_EVENT" ]]; then
    # Get the actual touch device name from libinput
    TOUCH_DEV_NAME=$(sudo libinput list-devices 2>/dev/null \
        | grep -B 10 "/dev/input/$TOUCH_EVENT" \
        | grep "^Device:" | tail -1 | sed 's/^Device:\s*//')

    if [[ -n "$TOUCH_DEV_NAME" ]]; then
        echo "Actual touch device name: $TOUCH_DEV_NAME"

        # Check if the system rc.xml has an explicit <touch> entry for this exact device
        SYSTEM_MATCH=$(grep -F "deviceName=\"$TOUCH_DEV_NAME\"" /etc/xdg/labwc/rc.xml 2>/dev/null)
        if [[ -n "$SYSTEM_MATCH" ]]; then
            echo "WARNING: System rc.xml has explicit <touch> mapping for this device!"
            echo "  This can interfere with labwc auto-detection and BREAK touch input."
            echo "  Consider removing this entry from /etc/xdg/labwc/rc.xml:"
            echo "  $SYSTEM_MATCH"
        else
            echo "OK: No explicit <touch> mapping for this device in system rc.xml (auto-detection will work)"
        fi
    else
        echo "(could not determine touch device name)"
    fi
else
    echo "(skipped - no touch event device detected)"
fi

# ---------- udev ----------

echo -e "\n=== UDEV RULES DIR ==="
ls -la /etc/udev/rules.d/

echo -e "\n=== UDEV RULES CONTENT ==="
cat /etc/udev/rules.d/* 2>/dev/null || echo "(empty)"

# ---------- dmesg ----------

echo -e "\n=== DMESG TOUCH ==="
dmesg | grep -i touch

echo -e "\n=== DMESG INPUT ==="
dmesg | grep -i input

echo -e "\n=== DMESG HID ==="
dmesg | grep -i hid

# ---------- labwc Config ----------

echo -e "\n=== LABWC CONFIG (user rc.xml) ==="
for f in "$LABWC_HOME/.config/labwc/rc.xml" \
         "$LABWC_HOME/.config/labwc/rc.bak" \
         "$LABWC_HOME/.config/labwc/rc.xml.bak"; do
    if [[ -f "$f" ]]; then
        echo "--- $f ---"
        cat "$f"
    fi
done

echo -e "\n=== LABWC CONFIG (system) ==="
for f in /etc/xdg/labwc/rc.xml; do
    if [[ -f "$f" ]]; then
        echo "--- $f ---"
        cat "$f"
    fi
done

echo -e "\n=== LABWC CONFIG (greeter) ==="
for f in /etc/xdg/labwc-greeter/rc.xml; do
    if [[ -f "$f" ]]; then
        echo "--- $f ---"
        cat "$f"
    fi
done

echo -e "\n=== LABWC CONFIG (gambit) ==="
for f in /etc/gambit/labwc-*.xml; do
    if [[ -f "$f" ]]; then
        echo "--- $f ---"
        cat "$f"
    fi
done

echo -e "\n=== LABWC ENVIRONMENT ==="
for f in "$LABWC_HOME/.config/labwc/environment" \
         /etc/xdg/labwc/environment; do
    if [[ -f "$f" ]]; then
        echo "--- $f ---"
        cat "$f"
    fi
done

# ---------- Session / Seat ----------

echo -e "\n=== LOGINCTL SESSIONS ==="
loginctl list-sessions --no-legend 2>/dev/null

echo -e "\n=== SEAT0 STATUS ==="
loginctl seat-status seat0 2>/dev/null

echo -e "\n=== SESSION TYPE ==="
loginctl show-session $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}' | head -1) -p Type 2>/dev/null || echo "(unknown)"

# ---------- Services & Processes ----------

echo -e "\n=== TOUCH-KERNEL-WATCH SERVICE ==="
systemctl status touch-kernel-watch 2>&1 || true

if [[ -n "$LABWC_USER" ]]; then
    echo -e "\n=== KIOSK SERVICE (user) ==="
    systemctl --user -M "${LABWC_USER}@.host" status kiosk 2>&1 || true

    echo -e "\n=== RPI-CONNECT UNITS (user) ==="
    systemctl --user -M "${LABWC_USER}@.host" list-units 2>/dev/null | grep rpi-connect || echo "(none)"
fi

echo -e "\n=== RELEVANT PROCESSES ==="
ps aux | grep -E "wayvnc|rpi-connect|squeekboard|labwc|chromium" | grep -v grep || echo "(none)"

# ---------- Kiosk Config ----------

if [[ -n "$LABWC_HOME" ]]; then
    echo -e "\n=== START-KIOSK.SH ==="
    if [[ -f "$LABWC_HOME/start-kiosk.sh" ]]; then
        cat "$LABWC_HOME/start-kiosk.sh"
    else
        echo "(not found at $LABWC_HOME/start-kiosk.sh)"
    fi
fi

echo -e "\n=== KIOSK SERVICE FILE ==="
if [[ -n "$LABWC_HOME" && -f "$LABWC_HOME/.config/systemd/user/kiosk.service" ]]; then
    cat "$LABWC_HOME/.config/systemd/user/kiosk.service"
else
    echo "(not found)"
fi

echo -e "\n=== KIOSK FLAG CHECK ==="
if [[ -n "$LABWC_HOME" && -f "$LABWC_HOME/start-kiosk.sh" ]]; then
    grep -n "touch-events\|password-store" "$LABWC_HOME/start-kiosk.sh" || echo "(flags not found)"
else
    echo "(start-kiosk.sh not found)"
fi

# ---------- Viam / Autotouch ----------

echo -e "\n=== AUTOTOUCH / VIAM JOURNAL (last 10) ==="
journalctl --no-pager -n 10 --grep="calibration applied|Touch device.*labwc|Wayland display.*ready" 2>/dev/null || echo "(no matches)"

# ---------- Boot Config ----------

echo -e "\n=== /boot/firmware/config.txt ==="
cat /boot/firmware/config.txt 2>/dev/null || echo "(not found)"

# ---------- Environment Files ----------

echo -e "\n=== /etc/environment ==="
cat /etc/environment 2>/dev/null

echo -e "\n=== ~/.profile ==="
cat ~/.profile 2>/dev/null

echo -e "\n=== ~/.bashrc (touch/rotate/wayland related) ==="
grep -iE "rotate|touch|wayland|display" ~/.bashrc 2>/dev/null || echo "(none)"

} > "$OUTPUT_FILE" 2>&1

echo "Diagnostics saved to: $OUTPUT_FILE"
echo "Compare with: diff touchscreen-diag-MACHINE1.txt touchscreen-diag-MACHINE2.txt"
