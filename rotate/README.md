# Raspberry Pi Auto-Rotate Display + Touch (0° / 180°)

Automatically rotate a Raspberry Pi display **and touchscreen** between **0° (normal)** and **180° (upside down)** using an **I2C accelerometer**.

Designed for **Raspberry Pi OS Bookworm (Wayland)**.

---

## Features

- Two orientations only: **0° and 180°**
- Rotates both **display and touch input**
- Stable (no jitter or rapid flipping)
- Works on Raspberry Pi OS **Bookworm (Wayland / labwc)**
- Uses `systemd` user service
- Starts automatically at boot

---

## Hardware

- **Raspberry Pi 5** (also works on Pi 4)
- **Accelerometer**: LIS3DH via I2C at address **0x18** (SDO→GND, default)
- **Display**: HDMI or DSI touchscreen (e.g., OSOYOO 3.5" DSI)

---

## Requirements

- Raspberry Pi OS **Bookworm**
- Wayland (default on Bookworm)
- I2C enabled

---

## Quick Start

### 1. Enable I2C

```bash
sudo raspi-config
# Interface Options → I2C → Enable
sudo reboot
```

### 2. Verify accelerometer

```bash
i2cdetect -y 1
```

You should see `18` in the grid (that's the address).

### 3. Run the setup script

```bash
chmod +x setup-autorotate.sh
sudo ./setup-autorotate.sh <username> <display-output> [touch-device-name]
```

Examples:

```bash
# Auto-detect touch device
sudo ./setup-autorotate.sh pi DSI-1

# Specify touch device manually
sudo ./setup-autorotate.sh pi DSI-1 "Goodix Capacitive TouchScreen"
```

To find your display output:

```bash
wlr-randr
```

To find your touch device name:

```bash
libinput list-devices | grep -A1 "Touch"
```

### 4. Reboot

```bash
sudo reboot
```

See [root README](../README.md#deployment-via-base64) for base64 deployment method.

---

## What the Script Does

1. Installs dependencies (`wlr-randr`, `python3`, `i2c-tools`, `adafruit-circuitpython-lis3dh`)
2. Adds user to `i2c` group
3. Auto-detects touch device (or uses provided name)
4. Creates udev rule for touch rotation
5. Creates `~/rotate-screen.py`
6. Creates and enables a systemd user service
7. Configures sudoers for passwordless udev updates

---

## Installed Files

| File | Purpose |
|------|---------|
| `~/rotate-screen.py` | Rotation logic |
| `~/.config/systemd/user/autorotate.service` | systemd service |
| `/etc/udev/rules.d/99-touch-rotation.rules` | Touch calibration |
| `/etc/sudoers.d/autorotate` | Passwordless udev access |

---

## Service Management

```bash
# Check status
systemctl --user status autorotate.service

# View logs
journalctl --user -u autorotate.service -f

# Restart
systemctl --user restart autorotate.service
```

---

## Configuration

Edit `~/rotate-screen.py` to adjust:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `DEADBAND` | 2.0 | m/s² threshold to ignore (increase if too sensitive) |
| `HOLD_COUNT` | 3 | Consecutive readings before rotation |
| `POLL` | 0.25 | Seconds between readings |

---

## Troubleshooting

**Screen doesn't rotate**
- Verify display output: `wlr-randr`
- Check service: `systemctl --user status autorotate.service`
- Check logs: `journalctl --user -u autorotate.service`

**Touch doesn't rotate with display**
- Verify touch device name: `libinput list-devices`
- Check udev rule: `cat /etc/udev/rules.d/99-touch-rotation.rules`
- Re-run setup with explicit touch device name

**I2C errors**
- Verify wiring (SDA/SCL)
- Check address: `i2cdetect -y 1` (should show `18`)
- Ensure I2C is enabled in `raspi-config`

**Permission denied**
- Logout and back in after install (for i2c group membership)

---

## Notes

- Uses I2C address `0x18` (SDO→GND, default)
- For address `0x19` (SDO→VCC), edit `rotate-screen.py`
- Touch rotation uses `LIBINPUT_CALIBRATION_MATRIX` via udev

---

## License

MIT