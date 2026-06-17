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
| `/usr/local/sbin/gambit-kiosk-recovery` | Root watchdog that recovers a missing kiosk session |
| `/etc/systemd/system/gambit-kiosk-recovery.service` | Root systemd service for kiosk recovery |

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

# Check root recovery watchdog
sudo systemctl status gambit-kiosk-recovery.service

# View recovery actions
sudo journalctl -u gambit-kiosk-recovery.service -f
```

---

## Configuration

Edit `/usr/local/bin/gambit-start-kiosk` or the user service environment to change:

| Variable | Default | Description |
|----------|---------|-------------|
| `KIOSK_URL` | `http://127.0.0.1:8765/kiosk/help` | URL to display |
| `SPLASH_PORT` | `8764` | Local splash server port |
| `WEB_CHECK_INTERVAL` | `5` | Seconds between local app health checks |
| `WEB_FAILURE_LIMIT` | `3` | Failed health checks before restarting Chromium at the splash |
| `MISSING_LIMIT` | `3` | Recovery watchdog missing-browser checks before restarting LightDM |
| `LIGHTDM_RESTART_COOLDOWN` | `60` | Minimum seconds between LightDM recovery restarts |

---

## Troubleshooting

**Kiosk doesn't start**
- Check service status (see above)
- Verify web server is running: `curl http://127.0.0.1:8765/kiosk/help`
- Check logs: `journalctl --user -u kiosk.service`

**Black screen / Chromium crashes**
- Check Chromium can run manually: `chromium --version`
- Try running the kiosk script directly: `~/start-kiosk.sh`
- If `systemctl --user` cannot reach the user manager, the root recovery watchdog restarts LightDM after the kiosk browser is missing for several checks.

**Web server not ready**
- The script keeps Chromium on the local splash until `KIOSK_URL` is reachable.
- If the local app later becomes unavailable, the launcher exits nonzero so `kiosk.service` restarts at the splash and waits again.
- `kiosk.service` uses `Restart=always` so a clean Chromium exit does not leave the display dark.
- `gambit-kiosk-recovery.service` covers the wider failure where the user session or user service manager is gone; it restarts LightDM so autologin recreates the Wayland session.

**Need to access the desktop for debugging (no SSH/WiFi)**
- Plug in a keyboard and press `Ctrl+Alt+F2` for a TTY login shell
- To restore the full Raspberry Pi desktop:
  ```bash
  sudo cp /etc/xdg/labwc/autostart.bak /etc/xdg/labwc/autostart
  sudo reboot
  ```
- To re-apply kiosk mode after, run `setup-kiosk-wayland.sh` again

---

## Deployment

See [root README](../README.md#deployment-via-base64) for base64 deployment method.
