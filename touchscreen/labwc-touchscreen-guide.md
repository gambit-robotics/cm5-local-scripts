# labwc Touchscreen Configuration Guide

## Quick Reference

**Issue:** Touchscreen not working on Raspberry Pi CM5 kiosk devices running labwc compositor.

**Root Cause:** Raspberry Pi OS ships `/etc/xdg/labwc/rc.xml` with wrong XML root element (`<openbox_config>` instead of `<labwc_config>`). labwc silently ignores all touch configuration.

**Fix:** Create/update user config at `~/.config/labwc/rc.xml` with correct syntax.

---

## The Fix

### For 180° Transform Displays (most devices)

```xml
<?xml version="1.0"?>
<labwc_config>
  <touch deviceName="0-0038 generic ft5x06 (00)" mapToOutput="DSI-2" mouseEmulation="yes"/>
</labwc_config>
```

**No calibration matrix needed** - `mapToOutput` handles the rotation.

### For 0° Transform Displays (needs testing - see Open Questions)

```xml
<?xml version="1.0"?>
<labwc_config>
  <touch deviceName="0-0038 generic ft5x06 (00)" mapToOutput="DSI-2" mouseEmulation="yes"/>
  <libinput>
    <device device="0-0038 generic ft5x06 (00)">
      <calibrationMatrix>-1 0 1 0 -1 1</calibrationMatrix>
    </device>
  </libinput>
</labwc_config>
```

**May need calibration matrix** - but this needs clean testing (see Open Questions).

### Quick Fix Commands

```bash
# 1. Find the user running the kiosk
ls /home/

# 2. Check display transform
sudo -u gambitadmin WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/$(id -u gambitadmin) wlr-randr

# 3. Check current config (note the wrong root element)
cat /home/gambitadmin/.config/labwc/rc.xml

# 4. Apply correct config (FOR 180° TRANSFORM - most common)
cat > /home/gambitadmin/.config/labwc/rc.xml << 'EOF'
<?xml version="1.0"?>
<labwc_config>
  <touch deviceName="0-0038 generic ft5x06 (00)" mapToOutput="DSI-2" mouseEmulation="yes"/>
</labwc_config>
EOF

# 5. Reload labwc
sudo pkill -HUP labwc

# 6. Test with PHYSICAL touch (not evemu over VNC - see Known Issues)
```

---

## Configuration Explained

### Root Element
- **Wrong:** `<openbox_config xmlns="http://openbox.org/3.4/rc">` - labwc ignores everything
- **Correct:** `<labwc_config>` - labwc processes the config

### Touch Element
```xml
<touch deviceName="0-0038 generic ft5x06 (00)" mapToOutput="DSI-2" mouseEmulation="yes"/>
```
- `deviceName`: Must match exactly from `libinput list-devices`
- `mapToOutput`: Display name from `wlr-randr` - handles coordinate mapping including rotation
- `mouseEmulation`: Converts touch to mouse events for apps that don't support touch

### Calibration Matrix
```xml
<calibrationMatrix>-1 0 1 0 -1 1</calibrationMatrix>
```
- Matrix `-1 0 1 0 -1 1` inverts both X and Y axes
- **Only add if physical touch is inverted after fixing root element**

### When to Use Calibration Matrix

| Display Transform | Matrix Needed | Status |
|-------------------|---------------|--------|
| 180° | No | **Confirmed** - mapToOutput handles it |
| 0° | Unknown | **Needs clean testing** - see Open Questions |

---

## Open Questions / To Test

### Does 0° Transform Need Matrix?

**Unknown.** TP2-RPi-CM5 (0° transform) had messy configs during testing that may have caused misleading results.

**Test procedure when TP2-RPi-CM5 is back online:**
```bash
# 1. Remove udev calibration rule
sudo rm /etc/udev/rules.d/99-touch-calibration.rules

# 2. Set clean user config WITHOUT matrix
cat > /home/tpastore/.config/labwc/rc.xml << 'EOF'
<?xml version="1.0"?>
<labwc_config>
  <touch deviceName="0-0038 generic ft5x06 (00)" mapToOutput="DSI-2" mouseEmulation="yes"/>
</labwc_config>
EOF

# 3. Reboot (udev rule removal requires reboot)
sudo reboot

# 4. Physical touch test
# - If works correctly → 0° doesn't need matrix
# - If inverted → 0° needs matrix
```

---

## Machines Needing Cleanup

### TP2-RPi-CM5

Has extra configs from debugging that may cause issues:

**Cleanup needed:**
```bash
# Remove duplicate udev calibration rule
sudo rm /etc/udev/rules.d/99-touch-calibration.rules

# Check/fix system config
head -5 /etc/xdg/labwc/rc.xml
# If shows <openbox_config>, it's broken but user config overrides it

# Ensure clean user config
cat /home/tpastore/.config/labwc/rc.xml
```

**Changes made during debugging (may need reverting):**
1. `~/start-kiosk.sh` - Added `--touch-events=enabled` to Chromium
2. `/etc/xdg/labwc/rc.xml` - Added touch config (but may have wrong root element)
3. `/etc/udev/rules.d/99-touch-calibration.rules` - Duplicate calibration matrix
4. Installed: `wev` (diagnostic tool - can leave)

---

## Known Issues

### VNC Mouse Inversion on 180° Displays

**Symptom:** When using wayvnc on a 180° rotated display, mouse input in VNC viewer is inverted (click bottom-right → cursor appears top-left).

**Cause:** wayvnc bug with rotated displays.

**Impact:** Cannot reliably test touch via evemu while watching VNC. The evemu events work, but VNC shows inverted feedback.

**Workaround:** Use physical touch testing, not VNC, for final verification on 180° displays.

### evemu Testing Limitations

On 180° displays without calibration matrix:
- `mapToOutput` inverts coordinates
- So raw evemu coords (50, 430) land at screen position (750, 50)
- This is correct behavior, but confusing when testing

**Recommendation:** Always do final verification with physical touch.

---

## Debugging Steps

### 1. Verify Touch Hardware Works

```bash
# Check if touch device exists
libinput list-devices | grep -A5 ft5x06

# Watch for touch events (tap screen physically)
sudo libinput debug-events
```

Expected output when touching:
```
event2   TOUCH_DOWN    ... (X/Y coordinates)
event2   TOUCH_FRAME
event2   TOUCH_UP
```

If no events: hardware problem, not config.

### 2. Check Display Configuration

```bash
# Run as the kiosk user
sudo -u <USER> WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/$(id -u <USER>) wlr-randr
```

Note:
- Display name (e.g., `DSI-2`)
- Transform value (e.g., `Transform: 180`)

### 3. Check Current labwc Config

```bash
# User config (takes priority)
cat ~/.config/labwc/rc.xml

# System config (fallback)
cat /etc/xdg/labwc/rc.xml
```

Look for the root element - if it says `openbox_config`, that's the problem.

### 4. Test Touch Injection with evemu

Install:
```bash
sudo apt install evemu-tools
```

Inject touch at center screen (400, 240 on 800x480 display):
```bash
sudo evemu-event /dev/input/event2 --type EV_ABS --code ABS_MT_TRACKING_ID --value 1 && \
sudo evemu-event /dev/input/event2 --type EV_ABS --code ABS_MT_POSITION_X --value 400 && \
sudo evemu-event /dev/input/event2 --type EV_ABS --code ABS_MT_POSITION_Y --value 240 && \
sudo evemu-event /dev/input/event2 --type EV_SYN --code SYN_REPORT --value 0 && \
sudo evemu-event /dev/input/event2 --type EV_ABS --code ABS_MT_TRACKING_ID --value -1 && \
sudo evemu-event /dev/input/event2 --type EV_SYN --code SYN_REPORT --value 0
```

Note: Confirm touch device is event2 first: `libinput list-devices | grep -A2 ft5x06`

### 5. Remote Testing via VNC

Setup wayvnc:
```bash
# Check if already running
ss -tlnp | grep 5900

# If not, start it
sudo -u <USER> WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/$(id -u <USER>) wayvnc 127.0.0.1 5900
```

Tunnel via Viam:
```bash
viam machines part tunnel --part <PART_ID> --destination-port 5900 --local-port 5900
```

Connect VNC Viewer to `localhost:5900`

---

## Common Issues

### Touch Events Seen but Not Reaching Apps

**Symptom:** `libinput debug-events` shows touches, but nothing happens in the app.

**Cause:** labwc not configured correctly (wrong root element).

**Fix:** Apply correct `<labwc_config>` as shown above.

### Touch Coordinates Inverted

**Symptom:** Tapping bottom-left clicks top-right (or vice versa).

**Cause:** Display is rotated 180° but calibration matrix not set.

**Fix:** Add the calibration matrix for 180° rotation:
```xml
<libinput>
  <device device="0-0038 generic ft5x06 (00)">
    <calibrationMatrix>-1 0 1 0 -1 1</calibrationMatrix>
  </device>
</libinput>
```

### Double Inversion

**Symptom:** Touch was inverted, added calibration matrix, still inverted (or now correct touches are inverted).

**Cause:** Both display transform AND calibration matrix are inverting.

**Fix:** Try without calibration matrix first. Only add it if touches are inverted.

### Config Changes Not Taking Effect

**Symptom:** Updated config but touch still broken.

**Causes:**
1. Didn't reload labwc: `sudo pkill -HUP labwc`
2. User config path wrong (must be `~/.config/labwc/rc.xml` for the user running labwc)
3. Syntax error in config (check XML is valid)

---

## System-Wide Fix

The root cause is in the system config. To fix for all users:

```bash
# Fix system config
sudo sed -i 's/<openbox_config xmlns="http:\/\/openbox.org\/3.4\/rc">/<labwc_config>/' /etc/xdg/labwc/rc.xml
sudo sed -i 's/<\/openbox_config>/<\/labwc_config>/' /etc/xdg/labwc/rc.xml

# Remove any broken user configs (optional - lets system config take over)
rm /home/*/.config/labwc/rc.xml

# Reload
sudo pkill -HUP labwc
```

**Note:** This should also be fixed in the base image for new deployments.

---

## Reference Information

### Config File Priority
1. `~/.config/labwc/rc.xml` (user config - wins if exists)
2. `/etc/xdg/labwc/rc.xml` (system config - fallback)

### Touch Device Details
- Device: `0-0038 generic ft5x06 (00)`
- Kernel path: `/dev/input/event2` (may vary)
- Coordinate range: X: 0-799, Y: 0-479

### Display Details
- Output: `DSI-2`
- Resolution: 800x480
- Physical size: 154x86 mm

### Known Affected Machines

| Machine | User | Transform | Matrix | Status |
|---------|------|-----------|--------|--------|
| user-research-1 | gambitadmin | 180° (assumed) | No | Needs fix |
| user-research-3 | gambitadmin | 180° | No | **Fixed** - needs physical test |
| user-research-4 | gambitadmin | 180° (assumed) | No | Needs fix |
| TP2-RPi-CM5 | tpastore | 0° | Unknown | **Needs cleanup** - see above |

### Viam Part IDs
- user-research-1: `33604ab0-737c-4481-baa2-b526ccb00362`
- user-research-3: `10e1ff5e-8432-4819-8fd2-e32f0f8dd6b3`
- user-research-4: `eeee358c-b6b0-443d-889c-66601d0f3417`
- TP2-RPi-CM5: `e7c9d354-042a-4c1e-bb66-e2240602f13a`

### Users by Machine
- user-research-*: `gambitadmin`
- TP2-RPi-CM5: `tpastore`

---

## Event Flow Diagram

```
Physical Touch
     ↓
/dev/input/event2 (kernel)
     ↓
libinput (applies calibrationMatrix IF configured)
     ↓
labwc compositor (mapToOutput applies display transform)
     ↓
Application (receives click/touch event)
```

**Key insight:** `mapToOutput="DSI-2"` maps touch coords to the output INCLUDING its transform. So on a 180° display, mapToOutput already inverts - adding a calibration matrix would double-invert.

If any step fails, touch doesn't work:
- Kernel: Check `libinput debug-events`
- libinput → labwc: Check `<labwc_config>` root element
- labwc → App: Check `mapToOutput` and `mouseEmulation`

---

## Summary

1. **Root cause:** Wrong XML root element (`<openbox_config>` vs `<labwc_config>`)
2. **Fix:** Correct the root element in user config
3. **180° displays:** No calibration matrix needed - `mapToOutput` handles it
4. **0° displays:** Unknown - needs clean testing on TP2-RPi-CM5
5. **VNC on 180° displays:** Mouse input is inverted (wayvnc bug) - use physical testing
6. **TP2-RPi-CM5:** Has leftover configs from debugging that need cleanup
