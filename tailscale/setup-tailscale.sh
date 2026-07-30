#!/usr/bin/env bash
# Join this device to the Gambit tailnet so it can reach shared services
# (GPU inference box, etc.) over an encrypted overlay network.
#
# Usage: sudo TS_AUTHKEY=tskey-auth-... ./setup-tailscale.sh
#   or place the key in /etc/gambit/tailscale-authkey (0600) beforehand.
set -euo pipefail

KEY="${TS_AUTHKEY:-}"
if [ -z "$KEY" ] && [ -f /etc/gambit/tailscale-authkey ]; then
  KEY="$(cat /etc/gambit/tailscale-authkey)"
fi
if [ -z "$KEY" ]; then
  echo "No auth key. Set TS_AUTHKEY or create /etc/gambit/tailscale-authkey" >&2
  exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
  echo "Installing tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

systemctl enable --now tailscaled

# --ssh enables tailscale-managed ssh to this device from the tailnet.
# Hostname: prefer the Viam-facing identity if the OS hostname is a factory
# default like 'raspberrypi'.
HOSTNAME_FLAG=""
if [ "$(hostname)" = "raspberrypi" ] || [[ "$(hostname)" == AlphaSN* ]]; then
  HOSTNAME_FLAG="--hostname=gambit-$(cut -c1-8 /etc/machine-id)"
fi

tailscale up --authkey "$KEY" --ssh $HOSTNAME_FLAG
echo "Joined tailnet as: $(tailscale ip -4 2>/dev/null | head -1)"
tailscale status | head -5
