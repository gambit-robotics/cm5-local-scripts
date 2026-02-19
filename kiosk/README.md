# Raspberry Pi Kiosk Mode for Chef Display

Automatically launch Chromium in fullscreen kiosk mode on boot, pointing to a local web server.

- **`setup-kiosk-wayland.sh`** - For Raspberry Pi OS Bookworm (Wayland/labwc)

---

## Features

- Fullscreen Chromium kiosk mode
- Auto-starts on boot
- Waits for web server to be ready (with timeout)
- Restarts on failure

---

## Hardware

- **Raspberry Pi 5** (also works on Pi 4)
- **Display**: Any HDMI or DSI display

---

## Requirements

- Raspberry Pi OS **Bookworm** (Wayland)
- Local web server running at `http://127.0.0.1:8765/kiosk/help`

---

## Quick Start

### 1. Run the setup script

```bash
chmod +x setup-kiosk-wayland.sh
sudo ./setup-kiosk-wayland.sh <username>
```

Example:
```bash
sudo ./setup-kiosk-wayland.sh pi
```

### 2. Reboot

```bash
sudo reboot
```

---

## What the Script Does

1. Install dependencies (`chromium`, `curl`)
2. Create `~/start-kiosk.sh` launcher script
3. Create and enable a systemd user service
4. Configure auto-start on boot

---

## Installed Files

| File | Purpose |
|------|---------|
| `~/start-kiosk.sh` | Kiosk launcher script |
| `~/.config/systemd/user/kiosk.service` | User systemd service |

---

## Service Management

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
- Check logs: `journalctl --user -u kiosk.service`

**Black screen / Chromium crashes**
- Check Chromium can run manually: `chromium --version`
- Try running the kiosk script directly: `~/start-kiosk.sh`

**Web server not ready**
- The script waits up to 60 seconds
- Ensure your web server starts before the kiosk service
- Adjust `MAX_WAIT` in `~/start-kiosk.sh` if needed

---

## Deployment

See [root README](../README.md#deployment-via-base64) for base64 deployment method.
