# Gambit CM5 Base Image

This directory contains the first-pass image tooling for the V1 CM5 golden
image. It follows the roadmap contract in `gambit-roadmap`:

- base image is Raspberry Pi OS Lite 64-bit
- the flashed artifact contains no per-device or fleet-wide secrets
- stable OS/runtime pieces are baked into the rootfs
- Viam provisioning, fleet config, and per-device enrollment happen after boot
- the `cm5-local-scripts` repo itself is not copied to the device

## Current Scope

The tooling here prepares an already-mounted root filesystem and boot
filesystem. It does not yet partition, mount, resize, or flash a disk image. That
keeps the first slice testable without a Linux loop-device builder while still
moving the install scripts toward a repeatable image pipeline.

```bash
sudo image/apply-rootfs.sh \
  --rootfs /mnt/gambit-root \
  --bootfs /mnt/gambit-boot \
  --image-version 0.1.0-dev \
  --viam-defaults image/viam-defaults.user-testing.json
```

Run the verifier directly against a mounted rootfs:

```bash
image/verify-rootfs.sh --rootfs /mnt/gambit-root
```

For a one-off assembled device that was flashed before these image steps were
baked in, copy and run the idempotent setup script on the Pi:

```bash
sudo image/setup-assembled-device.sh
sudo reboot
```

Publish a tested image artifact to the private R2 bucket:

```bash
export R2_ACCOUNT_ID=...
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...

make image-publish-r2 \
  RELEASE=2026-06-03-assembler-rc1 \
  ARTIFACT=dist/gambit-cm5-2026-06-03-assembler-rc1.img.xz \
  ROOTFS=/mnt/gambit-root \
  PRINT_URLS=1
```

The default destination is
`s3://gambit-device-images/device-images/cm5/<release>/`. Use `R2_BUCKET` or
`R2_PREFIX` to override that. The bucket should stay private; assembler access
should use short-lived signed URLs.

## What Gets Baked

- `/boot/firmware/config.txt` from `config/config.txt`
- `/etc/asound.conf`
- logind power-button drop-in
- `i2c-dev` boot module load config so `/dev/i2c-*` adapters are available
- LightDM/labwc kiosk session setup for `gambitadmin`, with Raspberry Pi
  first-user setup masked and DSI-2 rotated 180 degrees
- `/run/gambit` tmpfiles config
- boot chime asset and systemd unit
- CPU governor unit
- default screen brightness unit at 25%
- kiosk, buttons, and idle-dim runtime scripts/templates under `/usr/local` and
  `/usr/local/share/gambit`
- Plymouth assets/theme files
- `/etc/viam-defaults.json` for Viam BLE provisioning in the User Testing
  location; the image must not contain per-device `/etc/viam.json`
- image metadata at `/etc/gambit/image-build.json`

## R2 Release Contents

`image/publish-r2.sh` uploads an immutable release folder containing:

- the image artifact
- `<artifact>.sha256`
- `manifest.json`
- `FLASHING.md`
- `verification.txt`

Package dependencies are listed in `packages.txt`. Install them during the
image build stage before running `apply-rootfs.sh`; avoid first-boot apt
transactions except for tiny repair work owned by the future bootstrap module.
The package set includes OpenCV/GoCV system dependencies (`libopencv-dev`,
`pkg-config`, and build tooling), Python build headers/venv support
(`python3-dev`, `python3-venv`) for Viam Python modules that compile native
wheels, the local kiosk display stack (`lightdm`, `labwc`, `kanshi`,
`wlr-randr`), plus SQLite runtime and headers (`sqlite3`, `libsqlite3-0`, and
`libsqlite3-dev`).

## Not Yet Done

- full disk image copy/resize/mount pipeline
- RAUC/A-B partition layout
- OpenCV/GoCV package strategy validation on target hardware
- viam-agent offline install bundle wiring
- `gambit-device-bootstrap` module
- post-claim mTLS enrollment
