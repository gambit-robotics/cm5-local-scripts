# Gambit Safety Scripts

Raspberry Pi setup scripts and systemd services for kiosk displays, hardware monitoring, and peripheral control.

## Modules

| Module | Purpose | Scripts |
|--------|---------|---------|
| [buttons/](buttons/) | I2C volume control buttons | `setup-buttons.sh` |
| [rotate/](rotate/) | Auto-rotate display via accelerometer | `setup-autorotate.sh` |
| [kiosk/](kiosk/) | Chromium fullscreen kiosk | `setup-kiosk-wayland.sh`, `setup-kiosk-x11.sh` |
| [scripts/](scripts/) | Safety monitoring daemons | `pct2075_safety.py`, `ina219_safety.py` |
| [config/](config/) | Pi boot & audio configs | `config.txt`, `asound.conf` |

## Unified Installation

The `install.sh` script supports modular installation of all components:

```bash
# Safety monitoring only (default)
sudo ./install.sh

# Install config files (boot + audio)
sudo ./install.sh --config

# Install specific modules (requires username)
sudo ./install.sh --buttons <username>
sudo ./install.sh --rotate <username> <display-output> [touch-device]
sudo ./install.sh --kiosk <username>

# Install everything
sudo ./install.sh --all <username> <display-output> [touch-device]

# Config + shell services only (no Python safety scripts)
sudo ./install.sh --no-safety --config --buttons --kiosk <username>

# Show help
sudo ./install.sh --help
```

---

## Deployment via Base64

Scripts are transferred to Pi via base64 encoding to avoid issues with special characters, line endings, and shell escaping.

### Encode (local machine)

```bash
# macOS - copies to clipboard
base64 < path/to/script.sh | pbcopy

# Linux - print to stdout
base64 < path/to/script.sh
```

### Decode and run (Pi via SSH)

```bash
# Decode to file
echo 'PASTE_BASE64_HERE' | base64 -d > /tmp/script.sh
chmod +x /tmp/script.sh

# Run
sudo /tmp/script.sh <args>
```

### One-liner

```bash
echo 'BASE64_STRING' | base64 -d | sudo bash -s <args>
```

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
