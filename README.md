# Gambit Safety Scripts

Standalone systemd services that monitor hardware sensors via I2C and trigger graceful shutdown when safety thresholds are exceeded. These scripts run independently of Viam - if viam-server crashes, safety monitoring continues.

## Sensors Monitored

| Script | Sensor | Purpose |
|--------|--------|---------|
| `pct2075_safety.py` | PCT2075 | Ambient temperature monitoring |
| `mcp9601_safety.py` | MCP9601 | Thermocouple temperature monitoring |
| `ina219_safety.py` | INA219 | UPS battery level monitoring |

## Installation

```bash
sudo ./install.sh
```

This will:
1. Install Python dependencies
2. Copy scripts to `/opt/gambit/safety/`
3. Copy config to `/etc/gambit/safety-config.yaml`
4. Install and start systemd services

## Uninstallation

```bash
sudo ./uninstall.sh
```

## Configuration

Edit `/etc/gambit/safety-config.yaml`:

```yaml
pct2075:
  i2c_address: 0x37
  warning_temp_c: 70      # Log warning at this temperature
  shutdown_temp_c: 80     # Trigger shutdown at this temperature
  poll_interval_s: 5      # How often to check

mcp9601:
  i2c_address: 0x67
  warning_temp_c: 60
  shutdown_temp_c: 75
  poll_interval_s: 5

ina219:
  i2c_address: 0x42
  warning_battery_percent: 15    # Log warning at this level
  shutdown_battery_percent: 5    # Trigger shutdown at this level
  poll_interval_s: 10
  battery_cell_count: 3          # 3S LiPo pack
```

After editing, restart the services:

```bash
sudo systemctl restart pct2075-safety mcp9601-safety ina219-safety
```

## Behavior

Each script follows the same pattern:

1. Load config from `/etc/gambit/safety-config.yaml`
2. Initialize I2C sensor at configured address
3. Poll at configured interval
4. Log readings to journald
5. At warning threshold: log warning (once until recovered)
6. At shutdown threshold: log critical, run `shutdown -h +1 "Safety shutdown: <reason>"`

### Error Handling

- If I2C read fails: log error and retry on next poll
- After 5 consecutive failures: log critical but **do not shutdown** (hardware may be disconnected)
- Counter resets after any successful read

### Battery Monitoring (INA219)

- Only triggers shutdown when **discharging** (not while charging)
- Battery percentage calculated from voltage using linear interpolation
- Supports 1S-6S battery packs via `battery_cell_count` config

## Service Management

```bash
# Check status
sudo systemctl status pct2075-safety
sudo systemctl status mcp9601-safety
sudo systemctl status ina219-safety

# View logs
journalctl -u pct2075-safety -f
journalctl -u mcp9601-safety -f
journalctl -u ina219-safety -f

# Restart a service
sudo systemctl restart pct2075-safety

# Stop a service (temporary)
sudo systemctl stop pct2075-safety

# Disable a service (won't start on boot)
sudo systemctl disable pct2075-safety
```

## Testing

```bash
# Install test dependencies
pip install pytest pyyaml

# Run tests
pytest tests/ -v
```

## File Locations

| File | Location |
|------|----------|
| Scripts | `/opt/gambit/safety/` |
| Config | `/etc/gambit/safety-config.yaml` |
| Systemd units | `/etc/systemd/system/` |
| Logs | `journalctl -u <service-name>` |

## Requirements

- Python 3.9+
- Raspberry Pi or compatible SBC with I2C
- I2C enabled (`sudo raspi-config` -> Interface Options -> I2C)
- Root access (for shutdown command)

## Dependencies

- `adafruit-blinka` - CircuitPython compatibility layer
- `adafruit-circuitpython-pct2075` - PCT2075 temperature sensor
- `adafruit-circuitpython-mcp9600` - MCP9601 thermocouple amplifier
- `adafruit-circuitpython-ina219` - INA219 power monitor
- `pyyaml` - Configuration file parsing
