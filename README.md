# Gambit Safety Scripts

Raspberry Pi setup scripts and systemd services for kiosk displays, hardware monitoring, and peripheral control.

## Modules

| Module | Purpose | Scripts |
|--------|---------|---------|
| [buttons/](buttons/) | I2C volume control buttons | `setup-buttons.sh` |
| [rotate/](rotate/) | Auto-rotate display via accelerometer | `setup-autorotate.sh` |
| [kiosk/](kiosk/) | Chromium fullscreen kiosk | `setup-kiosk-wayland.sh`, `setup-kiosk-x11.sh` |
| [scripts/](scripts/) | Safety monitoring daemons | `pct2075_safety.py`, `ina219_safety.py` |

## Unified Installation

The `install.sh` script supports modular installation of all components:

```bash
# Safety monitoring only (default)
sudo ./install.sh

# Install specific modules (requires username)
sudo ./install.sh --buttons <username>
sudo ./install.sh --rotate <username> <display-output> [touch-device]
sudo ./install.sh --kiosk <username>

# Install everything
sudo ./install.sh --all <username> <display-output> [touch-device]

# Skip safety, install only user modules
sudo ./install.sh --no-safety --buttons --kiosk <username>

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
