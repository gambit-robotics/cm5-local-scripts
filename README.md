# Gambit CM5 Scripts

Raspberry Pi setup scripts for kiosk displays, boot splash, audio/firmware config, and peripheral control.

## Modules

| Module | Purpose | Scripts |
|--------|---------|---------|
| [buttons/](buttons/) | I2C volume control buttons | `setup-buttons.sh` |
| [kiosk/](kiosk/) | Chromium fullscreen kiosk | `setup-kiosk-wayland.sh` |
| [plymouth/](plymouth/) | Custom boot splash screen | `setup-bootsplash.sh` |
| [config/](config/) | Pi boot & audio configs | `config.txt`, `asound.conf` |

> **Auto-rotate** has been removed from this repo. Use [gambit-robotics/viam-accelerometer](https://github.com/gambit-robotics/viam-accelerometer) instead.

## Quick Start

Run `make` to see all available commands:

```bash
make              # Show help
make install-all  # Install everything (Pi)
make update-kiosk # Update single module (Pi)
```

User is auto-detected from `sudo`. Override with `USER=gambitadmin` if needed.

---

## Unified Installation

The `install.sh` script supports modular installation. Use `make` targets or call directly:

```bash
# Install everything (user auto-detected)
make install-all

# Or call install.sh directly
sudo ./install.sh --all gambitadmin

# Individual modules
make install-kiosk
make install-plymouth
make install-config
make install-buttons

# Show help
sudo ./install.sh --help
```

---

## Deployment

### 1. Clone on Pi

```bash
git clone https://github.com/gambit-robotics/cm5-local-scripts.git
cd cm5-local-scripts
```

### 2. Install

```bash
# Install everything (user auto-detected)
make install-all

# Reboot
sudo reboot
```

### Updating

```bash
cd cm5-local-scripts
git pull
make update-kiosk   # No reboot needed
```

---

## Buttons

I2C volume control using Arduino Modulino Buttons (ABX00110).

| Button | Action |
|--------|--------|
| A | Volume Down |
| B | (unused) |
| C | Volume Up |

**Config**: `~/.config/systemd/user/buttons.service`

```bash
systemctl --user status buttons
journalctl --user -u buttons -f
```

---

## Kiosk

Chromium fullscreen kiosk mode.

```bash
systemctl --user status kiosk
journalctl --user -u kiosk -f
```

---

## Plymouth (Boot Splash)

Custom boot splash screen using Plymouth.

```bash
make install-plymouth   # Install
make update-plymouth    # Update splash image
```

The theme uses `plymouth/splash.png` and scales it to fit the screen. Reboot required to see changes.

**Test without rebooting**:
```bash
sudo plymouthd --debug --tty=/dev/tty1
sudo plymouth show-splash
sleep 5
sudo plymouth quit
```

---

## Config Files

Reference configuration files for Raspberry Pi CM4/CM5.

| File | Destination | Purpose |
|------|-------------|---------|
| `config.txt` | `/boot/firmware/config.txt` | Boot config (I2C, SPI, display, camera) |
| `asound.conf` | `/etc/asound.conf` | ALSA audio routing for USB audio device |

Install with `make install-config`. Reboot required after changing `/boot/firmware/config.txt`.

---

## File Locations

| Type | Location |
|------|----------|
| User scripts | `$HOME/*.py`, `$HOME/*.sh` |
| User services | `$HOME/.config/systemd/user/*.service` |

---

## Requirements

- Raspberry Pi OS Bookworm (Wayland)
- Python 3.9+
- I2C enabled (`sudo raspi-config` → Interface Options → I2C)

### Verify I2C

```bash
ls /dev/i2c-*
i2cdetect -y 1
```

---

## Uninstall

```bash
# Uninstall specific modules
sudo ./uninstall.sh --buttons gambitadmin
sudo ./uninstall.sh --kiosk gambitadmin

# Uninstall everything
sudo ./uninstall.sh --all gambitadmin

# Show help
sudo ./uninstall.sh --help
```
