# Gambit CM5 Scripts

Raspberry Pi setup scripts for kiosk displays, boot splash, audio/firmware config, and peripheral control.

## Modules

| Module | Purpose | Scripts |
|--------|---------|---------|
| [buttons/](buttons/) | I2C volume control buttons | `setup-buttons.sh` |
| [kiosk/](kiosk/) | Chromium fullscreen kiosk | `setup-kiosk-wayland.sh` |
| [plymouth/](plymouth/) | Animated boot splash screen | `setup-bootsplash.sh` |
| [audio/](audio/) | Boot chime (plays early in boot) | `setup-audio.sh` |
| [config/](config/) | Pi boot, audio & power-button configs | `config.txt`, `asound.conf`, `logind-power-button.conf` |

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

## Base Image Tooling

The V1 golden-image work starts under [`image/`](image/). The current tooling
applies the Gambit runtime layer to already-mounted Raspberry Pi OS root and
boot filesystems, then verifies the no-secrets image contract.

```bash
make image-apply ROOTFS=/mnt/gambit-root BOOTFS=/mnt/gambit-boot IMAGE_VERSION=0.1.0-dev
make image-verify ROOTFS=/mnt/gambit-root
make image-test
```

This does not yet flash or partition an image. It is the pre-bake layer that the
outer Linux image builder will call after installing the package set in
`image/packages.txt`.

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
make install-audio
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

The theme uses `plymouth/SplashLoading.png` (scaled to fit the screen) and overlays three pulsing loading dots so users can tell the device is actively booting, not frozen on a static logo. The shutdown splash (`plymouth/SplashShutdown.png`) stays static. Reboot required to see changes.

**Test without rebooting**:
```bash
sudo plymouthd --debug --tty=/dev/tty1
sudo plymouth show-splash
sleep 5
sudo plymouth quit
```

---

## Audio (Boot Chime)

Plays Gambit's prep validation success chime as soon as ALSA is ready, giving audible "powering on" feedback before the DSI panel comes up.

```bash
make install-audio
```

- Asset: `/usr/local/share/gambit/boot-chime.wav` (copied from `audio/boot-chime.wav`; source of truth is `chef/internal/speech/adapters/chime/sounds/validationSuccess.wav`).
- Service: `gambit-boot-chime.service`, ordered `After=sound.target`, `WantedBy=multi-user.target`.
- **Volume**: the chime plays at the current ALSA `Speaker` level. If the device was muted or at 0% at last shutdown it plays silently — by design, to avoid stomping on operator settings.

---

## Config Files

Reference configuration files for Raspberry Pi CM4/CM5.

| File | Destination | Purpose |
|------|-------------|---------|
| `config.txt` | `/boot/firmware/config.txt` | Boot config (I2C, SPI, display, camera) |
| `asound.conf` | `/etc/asound.conf` | ALSA audio routing for USB audio device |
| `logind-power-button.conf` | `/etc/systemd/logind.conf.d/50-gambit-power-button.conf` | Ignore short taps, require >=5s hold to power off (GMBT-156) |

Install with `make install-config`. Reboot required after changing `/boot/firmware/config.txt`.

**Power button behaviour** (from `logind-power-button.conf`): a short tap does nothing; holding the IO-board power button for >=5 seconds triggers a clean shutdown. This prevents a boot-time panic-press loop where users, seeing the DSI panel dark during early boot, spam the power button and cause an on/off cycle.

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
