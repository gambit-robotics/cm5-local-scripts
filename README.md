# Gambit CM5 Scripts

Raspberry Pi setup scripts and systemd services for kiosk displays, hardware monitoring, and peripheral control.

/cm5-local-scripts are developed but are neither tested nor deployed

## Modules

| Module | Purpose | Scripts |
|--------|---------|---------|
| [buttons/](buttons/) | I2C volume control buttons | `setup-buttons.sh` |
| [rotate/](rotate/) | Auto-rotate display via accelerometer | `setup-autorotate.sh` |
| [kiosk/](kiosk/) | Chromium fullscreen kiosk | `setup-kiosk-wayland.sh`, `setup-kiosk-x11.sh` |
| [plymouth/](plymouth/) | Custom boot splash screen | `setup-bootsplash.sh` |
| [scripts/](scripts/) | Safety monitoring daemons | `pct2075_safety.py`, `ina219_safety.py` |
| [config/](config/) | Pi boot & audio configs | `config.txt`, `asound.conf` |

## Quick Start

Run `make` to see all available commands:

```bash
make              # Show help
make deploy       # Bundle + upload to dpaste (macOS)
make install-all DISPLAY=HDMI-A-1   # Install everything (Pi)
make update-rotate DISPLAY=HDMI-A-1 # Update single module (Pi)
```

User is auto-detected from `sudo`. Override with `USER=<name>` if needed.

---

## Unified Installation

The `install.sh` script supports modular installation. Use `make` targets or call directly:

```bash
# Install everything (user auto-detected)
make install-all DISPLAY=HDMI-A-1

# Or call install.sh directly
sudo ./install.sh --all <username> <display-output>

# Individual modules
make install-kiosk
make install-plymouth
make install-config
make install-buttons
make install-rotate DISPLAY=HDMI-A-1

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

# Find display output
wlr-randr | grep -E "^[A-Z]"

# Install everything (user auto-detected)
make install-all DISPLAY=HDMI-A-1

# Reboot
sudo reboot
```

### Updating a single module

```bash
# Re-deploy bundle, then on Pi:
curl -sL <URL>.txt | base64 -d | tar xzf - -C /tmp
cd /tmp/cm5-local-scripts
make update-rotate DISPLAY=HDMI-A-1   # Redeploys + restarts service
make update-kiosk                      # No reboot needed
```

### Quick reference

| Step | Command |
|------|---------|
| Deploy bundle | `make deploy` (Mac) |
| Download | `curl -sL <URL>.txt \| base64 -d \| tar xzf - -C /tmp` |
| Find display | `wlr-randr \| grep -E "^[A-Z]"` |
| Install all | `make install-all DISPLAY=HDMI-A-1` |
| Update module | `make update-rotate DISPLAY=HDMI-A-1` |

---

## Buttons

I2C volume control using Arduino Modulino Buttons (ABX00110).

```bash
# Deploy
base64 < buttons/setup-buttons.sh | pbcopy
# On Pi:
echo 'BASE64' | base64 -d > /tmp/setup-buttons.sh
sudo /tmp/setup-buttons.sh <username>
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

## Auto-Rotate

Rotate display + touch (0°/180°) using LIS3DH accelerometer.

```bash
# Deploy
base64 < rotate/setup-autorotate.sh | pbcopy
# On Pi:
echo 'BASE64' | base64 -d > /tmp/setup-autorotate.sh
sudo /tmp/setup-autorotate.sh <username> <display-output> [touch-device]
```

**Find display output**: `wlr-randr`
**Find touch device**: `libinput list-devices | grep -A1 Touch`

```bash
systemctl --user status autorotate
journalctl --user -u autorotate -f
```

---

## Kiosk

Chromium fullscreen kiosk mode.

```bash
# Deploy (Wayland - Bookworm default)
base64 < kiosk/setup-kiosk-wayland.sh | pbcopy
# On Pi:
echo 'BASE64' | base64 -d > /tmp/setup-kiosk.sh
sudo /tmp/setup-kiosk.sh <username>
```

**Check display server**:
```bash
echo $XDG_SESSION_TYPE   # wayland or x11
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

## Safety Monitoring

Standalone systemd services that monitor hardware sensors via I2C and trigger graceful shutdown when thresholds are exceeded. Runs independently of Viam.

| Script | Sensor | Purpose |
|--------|--------|---------|
| `pct2075_safety.py` | PCT2075 | Ambient temperature |
| `ina219_safety.py` | INA219 | UPS battery level |

### Installation

```bash
sudo ./install.sh
```

### Configuration

Edit `/etc/gambit/safety-config.yaml`:

```yaml
pct2075:
  i2c_address: 0x37
  warning_temp_c: 70
  shutdown_temp_c: 80
  poll_interval_s: 5

ina219:
  i2c_address: 0x41
  warning_battery_percent: 15
  shutdown_battery_percent: 5
  poll_interval_s: 10
  battery_cell_count: 3
```

```bash
sudo systemctl restart pct2075-safety ina219-safety
```

### Behavior

1. Poll sensor at configured interval
2. Log readings to journald
3. At warning threshold: log warning (once)
4. At shutdown threshold: `shutdown -h +1 "Safety shutdown: <reason>"`

**Error handling**: After 5 consecutive I2C failures, logs critical but does NOT shutdown (hardware may be disconnected).

```bash
sudo systemctl status pct2075-safety
journalctl -u pct2075-safety -f
```

---

## File Locations

| Type | Location |
|------|----------|
| Safety scripts | `/opt/gambit/safety/` |
| Safety config | `/etc/gambit/safety-config.yaml` |
| Safety services | `/etc/systemd/system/*.service` |
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

## Testing

```bash
pip install pytest pyyaml
pytest tests/ -v
```

---

## Uninstall

```bash
# Safety monitoring only (default)
sudo ./uninstall.sh

# Uninstall specific modules
sudo ./uninstall.sh --buttons <username>
sudo ./uninstall.sh --rotate <username>
sudo ./uninstall.sh --kiosk <username>

# Uninstall everything
sudo ./uninstall.sh --all <username>

# Show help
sudo ./uninstall.sh --help
```
