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

## Cross-repo contracts

- **`/run/gambit/cook-active` and `/run/gambit/session-active` (chef →
  gambit-input-idle daemon)**: chef creates `cook-active` while a cook
  timer is running and `session-active` while any cooking session is
  active. While either file exists, the lowpower screen-dim daemon
  (`lowpower/gambit-input-idle.sh`) suppresses dim regardless of input
  idle time, and restores within one tick (default 5s) if either file
  appears during a dimmed period. File contents are ignored — presence
  is the signal. Paths are configurable via `COOK_STATE_FILE` and
  `SESSION_STATE_FILE` env vars on the daemon's systemd unit (defaulted
  at install time). To minimise stale-file risk on chef crash, chef
  should remove these files at process start.
