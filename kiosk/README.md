# Raspberry Pi Kiosk Mode for Chef Display

Automatically launch Chromium in fullscreen kiosk mode on boot, pointing to a local web server.

Two scripts are provided for different display servers:
- **`setup-kiosk-wayland.sh`** - For Raspberry Pi OS Bookworm (Wayland/labwc) - **recommended**
- **`setup-kiosk-x11.sh`** - For legacy X11 systems

---

## Features

- Fullscreen Chromium kiosk mode
- Auto-starts on boot
- Waits for web server to be ready (with timeout)
- Disables screensaver and power management (X11)
- Hides mouse cursor (X11)
- Restarts on failure

---

## Hardware

- **Raspberry Pi 5** (also works on Pi 4)
- **Display**: Any HDMI or DSI display

---

## Requirements

- Raspberry Pi OS **Bookworm** (for Wayland) or earlier (for X11)
- Local web server running at `http://127.0.0.1:8765/kiosk/help`

---

## Quick Start

### 1. Check your display server

```bash
loginctl show-session $(loginctl list-sessions | grep $(whoami) | awk '{print $1}' | head -1) -p Type
```

- `Type=wayland` → Use `setup-kiosk-wayland.sh`
- `Type=x11` → Use `setup-kiosk-x11.sh`

### 2. Run the appropriate setup script

**For Wayland (Bookworm default):**
```bash
chmod +x setup-kiosk-wayland.sh
sudo ./setup-kiosk-wayland.sh <username>
```

**For X11:**
```bash
chmod +x setup-kiosk-x11.sh
sudo ./setup-kiosk-x11.sh <username>
```

Example:
```bash
sudo ./setup-kiosk-wayland.sh pi
```

### 3. Reboot

```bash
sudo reboot
```

---

## What the Scripts Do

1. Install dependencies (`chromium`, `curl`, `unclutter` for X11)
2. Create `~/start-kiosk.sh` launcher script
3. Create and enable a systemd service
4. Configure auto-start on boot

---

## Installed Files

### Wayland Version

| File | Purpose |
|------|---------|
| `~/start-kiosk.sh` | Kiosk launcher script |
| `~/.config/systemd/user/kiosk.service` | User systemd service |

### X11 Version

| File | Purpose |
|------|---------|
| `~/start-kiosk.sh` | Kiosk launcher script |
| `/etc/systemd/system/kiosk.service` | System systemd service |

---

## Service Management

### Wayland (user service)

```bash
# Check status
systemctl --user status kiosk.service

# View logs
journalctl --user -u kiosk.service -f

# Restart
systemctl --user restart kiosk.service

# Stop
systemctl --user stop kiosk.service
```

### X11 (system service)

```bash
# Check status
sudo systemctl status kiosk.service

# View logs
sudo journalctl -u kiosk.service -f

# Restart
sudo systemctl restart kiosk.service

# Stop
sudo systemctl stop kiosk.service
```

---

## Configuration

Edit `~/start-kiosk.sh` to change:

| Variable | Default | Description |
|----------|---------|-------------|
| `KIOSK_URL` | `http://127.0.0.1:8765/kiosk/help` | URL to display |
| `MAX_WAIT` | `60` | Seconds to wait for web server |

---

## Troubleshooting

**Kiosk doesn't start**
- Check service status (see above)
- Verify web server is running: `curl http://127.0.0.1:8765/kiosk/help`
- Check logs: `journalctl --user -u kiosk.service` (Wayland) or `sudo journalctl -u kiosk.service` (X11)

**Wrong display server**
- Check with: `echo $XDG_SESSION_TYPE`
- Use the matching script (wayland vs x11)

**Black screen / Chromium crashes**
- Check Chromium can run manually: `chromium --version`
- Try running the kiosk script directly: `~/start-kiosk.sh`

**Web server not ready**
- The script waits up to 60 seconds
- Ensure your web server starts before the kiosk service
- Adjust `MAX_WAIT` in `~/start-kiosk.sh` if needed

---

## Differences Between Versions

| Feature | Wayland | X11 |
|---------|---------|-----|
| Display variable | `WAYLAND_DISPLAY` | `DISPLAY=:0` |
| Chromium flag | `--ozone-platform=wayland` | None |
| Screensaver disable | Not needed | `xset s off` |
| Hide cursor | Not needed | `unclutter` |
| Service type | User service | System service |
| Pi OS version | Bookworm+ | Any |

---

## Installation via SSH (Shell-Only Access)

If you only have SSH shell access (e.g., via `viam machine part shell` or similar), use the base64 encoding method:

### 1. On your local machine, encode the script:

```bash
base64 -i setup-kiosk-wayland.sh
```

### 2. On the Raspberry Pi, decode and create the file:

```bash
echo '<paste base64 output here>' | base64 -d > ~/setup-kiosk-wayland.sh
chmod +x ~/setup-kiosk-wayland.sh
```

### 3. Run the setup:

```bash
sudo ~/setup-kiosk-wayland.sh <username>
```

---

## License

MIT
