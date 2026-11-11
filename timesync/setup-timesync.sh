#!/usr/bin/env bash
# Set the clock within about a second of the network coming up, and start the next boot close
# to the right time (GMBT-1615).
#
# The CM5 has no RTC battery: it boots at 1970 and systemd moves the clock up to the mtime of
# /var/lib/systemd/timesync/clock. Stock systemd-timesyncd saves that every 5 minutes and, under
# NetworkManager, first reaches a server ~34 s after boot (it retries only after
# ConnectionRetrySec). chrony replaces it: NetworkManager's 20-chrony-onoffline hook brings its
# sources online with the network, and iburst at minpoll -1 sets the clock ~1.6 s after the DHCP
# lease. A timer keeps the clock file current for the next boot.
#
# gambit-wait-clock then holds viam-agent until the clock is set, so the data manager never
# captures under the stale time, but only while something can set it: a box that is not set up
# yet (no /etc/viam.json) or has no saved network in range starts viam-agent at once, because
# its Bluetooth setup may be how the box gets a network.
#
# Usage: sudo ./setup-timesync.sh                 # this machine (installs chrony if missing)
#        ./setup-timesync.sh --rootfs PATH        # a mounted image rootfs (chrony from packages.txt)
#
# The overhead-hardware fragment runs this script as a job. viam-server reads dollar-brace
# expressions in config values as placeholders, so the script must not contain any.
set -euo pipefail

ROOT=""
if [[ $# -ge 1 && "$1" == "--rootfs" ]]; then
    [[ $# -ge 2 ]] || { echo "--rootfs needs a path" >&2; exit 2; }
    ROOT="$2"
fi

if [[ -z "$ROOT" ]] && ! dpkg -s chrony 2>/dev/null | grep -qx "Status: install ok installed"; then
    [[ -n "$(printenv SKIP_APT_UPDATE)" ]] || apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq chrony
fi

changed=false
put() { # put <mode> <path>: write stdin to ROOT/path if it differs
    local dst="$ROOT$2" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    if ! cmp -s "$tmp" "$dst"; then
        mkdir -p "$(dirname "$dst")"
        install -m "$1" "$tmp" "$dst"
        changed=true
    fi
    rm -f "$tmp"
}

put 0644 /etc/chrony/conf.d/gambit.conf <<'CONF'
# Gambit (GMBT-1615): set the clock about half a second after the network comes up.
# Cloudflare's anycast time servers: the nearest Cloudflare location answers.
# - By IPv4 address, so a boot that starts without a network needs no DNS.
# - By name too: on a network with IPv6 the name resolves to Cloudflare's IPv6 address, and it
#   follows Cloudflare if the addresses change. On IPv4 it resolves to an address above and
#   adds nothing. Literal IPv6 addresses would cost ~0.8 s on IPv4-only networks: chrony
#   holds the first clock update until every source on the same schedule has 3 samples.
# minpoll -1 sends iburst's first requests 0.5 s apart instead of 2 s (faster gains nothing);
# chrony backs off toward maxpoll once the clock is stable. Debian's pool is the fallback.
server 162.159.200.1 iburst minpoll -1 maxpoll 10
server 162.159.200.123 iburst minpoll -1 maxpoll 10
server time.cloudflare.com iburst minpoll -1 maxpoll 10
# Step any offset over 0.1 s, not only in the first 3 updates (Debian's default is 1 s, 3).
makestep 0.1 -1
CONF

put 0644 /etc/systemd/system/gambit-clock-save.service <<'UNIT'
[Unit]
Description=Gambit: save the time for the next boot (no RTC battery; systemd starts the clock from this file's mtime)

[Service]
Type=oneshot
ExecStart=/usr/bin/mkdir -p /var/lib/systemd/timesync
ExecStart=/usr/bin/touch /var/lib/systemd/timesync/clock
UNIT

put 0644 /etc/systemd/system/gambit-clock-save.timer <<'UNIT'
[Unit]
Description=Gambit: save the time every minute for the next boot

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT

put 0755 /usr/local/sbin/gambit-wait-clock <<'GATE'
#!/bin/sh
# Hold viam-agent until the clock is set (GMBT-1615), but only while something can set it.
say() { echo "gambit-wait-clock: $1 at $(cut -d' ' -f1 /proc/uptime) s"; exit 0; }
[ -s /etc/viam.json ] || say "not set up yet, not waiting"
command -v chronyc >/dev/null || say "no chrony, not waiting"
synced() { chronyc -n tracking 2>/dev/null | grep -q '^Leap status *: Normal'; }
i=0 online=""
while [ "$i" -lt 100 ]; do
    synced && say "clock set"
    # NetworkManager's startup completes once it has brought up a saved network in range, or found none.
    if [ -z "$online" ] && nm-online -s -q -t 0; then
        case "$(nmcli -t -f STATE general 2>/dev/null)" in
            connected*|connecting*) online=$i ;;
            *) say "no network, not waiting" ;;
        esac
    fi
    [ -n "$online" ] && [ $((i - online)) -ge 40 ] && say "clock still not set 10 s after the network came up"
    sleep 0.25
    i=$((i + 1))
done
say "network still not up after 25 s"
GATE

put 0644 /etc/systemd/system/viam-agent.service.d/gambit-wait-clock.conf <<'UNIT'
[Unit]
After=chrony.service NetworkManager.service

[Service]
ExecStartPre=-/usr/local/sbin/gambit-wait-clock
UNIT

if [[ -n "$ROOT" ]]; then
    install -d -m 0755 "$ROOT/etc/systemd/system/timers.target.wants"
    ln -sfn ../gambit-clock-save.timer "$ROOT/etc/systemd/system/timers.target.wants/gambit-clock-save.timer"
    exit 0
fi

systemctl daemon-reload
systemctl enable --now gambit-clock-save.timer
if $changed; then
    systemctl restart chrony
fi
echo "timesync: chrony $(dpkg-query -W chrony | cut -f2), $(chronyc -n tracking | grep -E '^(Reference ID|Leap status)' | tr -s ' ' | paste -sd ';' -)"
