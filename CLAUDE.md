# CLAUDE.md — cm5-local-scripts

Per-repo notes for the CM5 device-bootstrap scripts. Cross-repo workflow,
device hardware facts, boot timing, and module conventions live in the
workspace-level `CLAUDE.md` at `../CLAUDE.md` — read that first.

## Architectural learnings

- [GMBT-377] Wayland's idle-inhibit protocol (`zwlr_idle_inhibit_v1`) makes
  swayidle a no-op on labwc while Chromium kiosk is up — Chromium holds
  the inhibitor for WebRTC streams and the Wake Lock API, and the
  compositor never delivers the timeout. Bypass it by reading
  `/dev/input/*` directly via `libinput debug-events` (channel sits beneath
  the compositor, not subject to the inhibit protocol). See
  `lowpower/gambit-input-idle.sh`. Same trick generalises to any other
  below-compositor idle / activity check we might want on this platform.
