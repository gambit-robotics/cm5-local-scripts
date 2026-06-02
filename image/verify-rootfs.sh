#!/usr/bin/env bash
set -euo pipefail

ROOTFS=""

usage() {
    cat <<'EOF'
Usage: image/verify-rootfs.sh --rootfs PATH

Checks a mounted rootfs for the no-secrets image contract.
EOF
}

die() { echo "Error: $*" >&2; exit 1; }
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootfs) ROOTFS="${2:-}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$ROOTFS" ]] || die "--rootfs is required"
[[ -d "$ROOTFS" ]] || die "rootfs does not exist: $ROOTFS"

failures=0

if [[ -f "$ROOTFS/etc/shadow" ]]; then
while IFS=: read -r user hash _rest; do
        [[ -z "$user" ]] && continue
        if [[ "$hash" =~ ^\$[A-Za-z0-9] ]]; then
            fail "login password hash is baked for user '$user'"
        fi
    done < "$ROOTFS/etc/shadow"
fi

while IFS= read -r path; do
    fail "authorized_keys is baked: ${path#$ROOTFS/}"
done < <(find "$ROOTFS" -path '*/.ssh/authorized_keys' -type f 2>/dev/null || true)

while IFS= read -r path; do
    fail "SSH host private key is baked: ${path#$ROOTFS/}"
done < <(find "$ROOTFS/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*_key' 2>/dev/null || true)

for viam_config in "$ROOTFS/etc/viam.json" "$ROOTFS/etc/viam-defaults.json"; do
    if [[ -f "$viam_config" ]] && grep -Eq '"secret"[[:space:]]*:[[:space:]]*"[^"]+"' "$viam_config"; then
        fail "${viam_config#$ROOTFS/} contains a cloud secret"
    fi
done

if [[ -d "$ROOTFS/etc/gambit/identity" ]]; then
    while IFS= read -r path; do
        fail "device identity material is baked: ${path#$ROOTFS/}"
    done < <(find "$ROOTFS/etc/gambit/identity" -type f \( -name '*.key' -o -name '*.crt' -o -name '*.pem' \) 2>/dev/null || true)
fi

while IFS= read -r path; do
    case "${path#$ROOTFS/}" in
        etc/ssl/certs/*|usr/share/ca-certificates/*|usr/local/share/ca-certificates/*)
            continue
            ;;
    esac
    if grep -Iq . "$path" && grep -Eq 'BEGIN PRIVATE KEY|BEGIN RSA PRIVATE KEY|BEGIN EC PRIVATE KEY|BEGIN OPENSSH PRIVATE KEY|PRIVATE KEY-----' "$path"; then
        fail "private key PEM content is baked: ${path#$ROOTFS/}"
    fi
done < <(find "$ROOTFS/etc" "$ROOTFS/usr/local" "$ROOTFS/var/lib/gambit" -type f 2>/dev/null || true)

while IFS= read -r path; do
    fail "cm5-local-scripts repo material is baked: ${path#$ROOTFS/}"
done < <(find "$ROOTFS" \( -name '.git' -o -name 'install.sh' -o -name 'uninstall.sh' -o -name 'Makefile' \) 2>/dev/null | grep -E 'cm5-local-scripts|/opt/gambit/source|/home/.*/cm5-local-scripts' || true)

secret_pattern='((^|[^[:alnum:]])(api[_-]?key|apikey)([^[:alnum:]]|$)|cloudflare[_-]?api|atlas|mongodb://|mongodb[+]srv://|elevenlabs|anthropic|openai|gemini|sk-[A-Za-z0-9_-]{20,}|password:[[:space:]]*[^[:space:]]+)'
while IFS= read -r path; do
    case "${path#$ROOTFS/}" in
        etc/gambit/image-build.json)
            continue
            ;;
    esac
    if grep -Iq . "$path" && grep -Eiq "$secret_pattern" "$path"; then
        fail "possible secret-bearing text in ${path#$ROOTFS/}"
    fi
done < <(find "$ROOTFS/etc" "$ROOTFS/usr/local" "$ROOTFS/var/lib/gambit" -type f -size -512k 2>/dev/null || true)

if [[ "$failures" -gt 0 ]]; then
    echo "Rootfs verification failed with $failures issue(s)." >&2
    exit 1
fi

echo "Rootfs verification passed."
