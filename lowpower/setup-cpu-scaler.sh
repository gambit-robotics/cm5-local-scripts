#!/bin/bash
set -euo pipefail

# Deprecated: the gambit-cpu-scaler.service userspace daemon has been
# superseded by chef's in-process CPU scaler (chef/internal/cpuscaler).
# Two writers contending for /sys/.../cpuN/online produced races; chef's
# scaler also avoids shelling out to `viam machines part run` for state.
#
# This script now disables and removes the old service if present, on
# every `--lowpower` install. Idempotent: a no-op on devices where the
# service was never installed or was already removed.
#
# It does NOT touch /boot/firmware/cmdline.txt. Earlier versions of this
# script stripped `maxcpus=` from cmdline.txt to enable hot-plug; that
# is no longer relevant. Admins who want a hard kernel-level core cap
# (e.g. on devices with broken PSCI hot-plug) can add `maxcpus=N` to
# cmdline.txt manually.

die() { echo "Error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run with sudo"

SERVICE_NAME="gambit-cpu-scaler.service"
SERVICE_DST="/etc/systemd/system/$SERVICE_NAME"
DEFAULTS_DST="/etc/default/gambit-cpu-scaler"

echo "=== Gambit CPU Scaler Teardown (deprecated) ==="

removed_any=0

if systemctl list-unit-files "$SERVICE_NAME" --no-legend | grep -q "$SERVICE_NAME"; then
    echo "  disabling and stopping $SERVICE_NAME"
    systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    removed_any=1
fi

if [[ -f "$SERVICE_DST" ]]; then
    echo "  removing $SERVICE_DST"
    rm -f "$SERVICE_DST"
    removed_any=1
fi

if [[ -f "$DEFAULTS_DST" ]]; then
    echo "  removing $DEFAULTS_DST"
    rm -f "$DEFAULTS_DST"
    removed_any=1
fi

if (( removed_any )); then
    systemctl daemon-reload
    echo "  done — chef's in-process scaler now owns CPU scaling"
else
    echo "  nothing to remove (already deprecated)"
fi
