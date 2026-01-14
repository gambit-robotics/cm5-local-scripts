# I2C Button Controller

Setup script for Arduino Modulino Buttons (ABX00110) on Raspberry Pi.

## Features

- **Volume control**: Buttons A/C adjust system volume via ALSA
- **Repeat-while-held**: Hold button to continuously adjust volume (200ms rate)
- **LED feedback**: LEDs light while buttons are pressed
- **Configurable**: I2C address, volume step, mixer name via environment

## Hardware

- **Device**: Arduino Modulino Buttons (ABX00110)
- **I2C Address**: 0x3E (hardware address, configurable)
- **I2C Bus**: /dev/i2c-1
- **Protocol**: Read 4 bytes (skip pinstrap byte), write 3 bytes for LEDs

## Files

### Source (this repo)
```
buttons/
├── README.md
└── setup-buttons.sh      # Setup script (run on Pi)
```

### Created by setup script
```
$HOME/
├── button-controller.py              # Python service script
└── .config/systemd/user/
    └── buttons.service               # Systemd user service
```

## Installation

See [root README](../README.md#deployment-via-base64) for base64 deployment method.

```bash
sudo ./setup-buttons.sh <username>
```

## Button Mapping

| Button | Action | Behavior |
|--------|--------|----------|
| A | Volume Down | Repeat while held |
| B | (unused) | Reserved for future |
| C | Volume Up | Repeat while held |

## Service Commands

```bash
# Manage service (run as the kiosk user, not root)
systemctl --user start buttons     # Start service
systemctl --user stop buttons      # Stop service
systemctl --user restart buttons   # Restart service
systemctl --user status buttons    # Check status

# View logs
journalctl --user -u buttons -f    # Follow logs
journalctl --user -u buttons -n 50 # Last 50 lines
```

## Configuration

Environment variables in `~/.config/systemd/user/buttons.service`:

| Variable | Default | Description |
|----------|---------|-------------|
| BUTTON_I2C_ADDR | 0x3E | I2C address (hex) |
| VOLUME_STEP | 5 | Volume change per step (%) |
| POLL_INTERVAL | 0.05 | Button polling interval (seconds) |
| ALSA_MIXER | Speaker | ALSA mixer control name |

### Changing configuration

```bash
# Edit the service file
nano ~/.config/systemd/user/buttons.service

# Reload and restart
systemctl --user daemon-reload
systemctl --user restart buttons
```

### Finding your ALSA mixer name

```bash
amixer scontrols
# Output example:
# Simple mixer control 'Speaker',0
# Simple mixer control 'Mic',0
```

## Testing

### Verify I2C

```bash
# Check I2C is enabled
ls /dev/i2c-*

# Scan for devices (should show 67)
i2cdetect -y 1
```

### Test volume control

```bash
# Check current volume
amixer sget Speaker

# Test volume commands
amixer sset Speaker 5%+
amixer sset Speaker 5%-
```

### Test service

```bash
# Check service status
systemctl --user status buttons

# Watch logs while pressing buttons
journalctl --user -u buttons -f
```

## Timing

| Parameter | Value | Description |
|-----------|-------|-------------|
| Poll interval | 50ms | Button state check frequency |
| Repeat delay | 400ms | Time before repeat starts |
| Repeat rate | 200ms | Interval between repeats while held |

## Troubleshooting

### Service won't start

```bash
# Check if I2C device is accessible
i2cdetect -y 1 | grep 67

# Check user is in i2c group
groups

# If not in i2c group, add and relogin
sudo usermod -aG i2c $USER
```

### No volume change

```bash
# Verify mixer name
amixer scontrols

# Test manually
amixer sset Speaker 50%

# Check service is using correct mixer
journalctl --user -u buttons | head -5
# Should show: Started: I2C=0x3e, mixer=Speaker, step=5%
```

### I2C errors in logs

```bash
# Check wiring and device address
i2cdetect -y 1

# Verify I2C is enabled in config
sudo raspi-config
# Interface Options > I2C > Enable
```
