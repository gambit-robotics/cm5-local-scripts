# Gambit CM5 Scripts

Raspberry Pi setup scripts and systemd services for kiosk displays, hardware monitoring, and peripheral control.

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
make deploy       # Bundle + upload to dpaste (macOS)
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

## Remote Deployment (Viam Shell)

For deploying to Pis accessible only via Viam remote shell (no direct SSH).

### 1. Bundle and upload (Mac)

```bash
make deploy
# Outputs URL like: https://dpaste.com/ABC123
```

### 2. Deploy to Pi (Viam shell)

```bash
# Download and extract
curl -sL https://dpaste.com/ABC123.txt | base64 -d | tar xzf - -C /tmp
cd /tmp/cm5-local-scripts

# Install everything (user auto-detected)
make install-all

# Reboot
sudo reboot
```

### Updating a single module

```bash
# Re-deploy bundle, then on Pi:
curl -sL <URL>.txt | base64 -d | tar xzf - -C /tmp
cd /tmp/cm5-local-scripts
make update-kiosk                     # No reboot needed
```

### Quick reference

| Step | Command |
|------|---------|
| Deploy bundle | `make deploy` (Mac) |
| Download | `curl -sL <URL>.txt \| base64 -d \| tar xzf - -C /tmp` |
| Install all | `make install-all` |
| Update module | `make update-kiosk` |

---

## Buttons

I2C volume control using Arduino Modulino Buttons (ABX00110).

```bash
# Deploy
base64 < buttons/setup-buttons.sh | pbcopy
# On Pi:
echo 'BASE64' | base64 -d > /tmp/setup-buttons.sh
sudo /tmp/setup-buttons.sh gambitadmin
```

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
# Deploy (Wayland - Bookworm default)
base64 < kiosk/setup-kiosk-wayland.sh | pbcopy
# On Pi:
echo 'BASE64' | base64 -d > /tmp/setup-kiosk.sh
sudo /tmp/setup-kiosk.sh gambitadmin
```

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

### Deploy

```bash
# Boot config
base64 < config/config.txt | pbcopy
# On Pi:
echo 'BASE64' | base64 -d | sudo tee /boot/firmware/config.txt

# Audio config
base64 < config/asound.conf | pbcopy
# On Pi:
echo 'BASE64' | base64 -d | sudo tee /etc/asound.conf
```

**Note**: Reboot required after changing `/boot/firmware/config.txt`.

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
