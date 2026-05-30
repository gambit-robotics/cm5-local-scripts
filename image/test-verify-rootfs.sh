#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="$SCRIPT_DIR/verify-rootfs.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_rootfs() {
    local dir="$1"
    mkdir -p "$dir/etc" "$dir/usr/local/bin" "$dir/var/lib/gambit"
    cat > "$dir/etc/shadow" <<'EOF'
root:!:19876:0:99999:7:::
daemon:*:19876:0:99999:7:::
EOF
}

pass_root="$tmp/pass"
make_rootfs "$pass_root"
"$VERIFY" --rootfs "$pass_root" >/dev/null

hash_root="$tmp/hash"
make_rootfs "$hash_root"
cat >> "$hash_root/etc/shadow" <<'EOF'
gambitadmin:$y$j9T$abc$def:19876:0:99999:7:::
EOF
if "$VERIFY" --rootfs "$hash_root" >/dev/null 2>&1; then
    echo "expected password hash fixture to fail" >&2
    exit 1
fi

key_root="$tmp/key"
make_rootfs "$key_root"
mkdir -p "$key_root/etc/ssh"
touch "$key_root/etc/ssh/ssh_host_ed25519_key"
if "$VERIFY" --rootfs "$key_root" >/dev/null 2>&1; then
    echo "expected SSH host key fixture to fail" >&2
    exit 1
fi

viam_root="$tmp/viam"
make_rootfs "$viam_root"
cat > "$viam_root/etc/viam.json" <<'EOF'
{"cloud":{"secret":"fleet-secret"}}
EOF
if "$VERIFY" --rootfs "$viam_root" >/dev/null 2>&1; then
    echo "expected viam secret fixture to fail" >&2
    exit 1
fi

viam_defaults_root="$tmp/viam-defaults"
make_rootfs "$viam_defaults_root"
cat > "$viam_defaults_root/etc/viam-defaults.json" <<'EOF'
{"cloud":{"secret":"default-secret"}}
EOF
if "$VERIFY" --rootfs "$viam_defaults_root" >/dev/null 2>&1; then
    echo "expected viam-defaults secret fixture to fail" >&2
    exit 1
fi

secret_root="$tmp/secret"
make_rootfs "$secret_root"
cat > "$secret_root/usr/local/bin/leaky-config" <<'EOF'
OPENAI_API_KEY=sk-testsecretthatshouldnotbebaked
EOF
if "$VERIFY" --rootfs "$secret_root" >/dev/null 2>&1; then
    echo "expected possible secret fixture to fail" >&2
    exit 1
fi

echo "verify-rootfs tests passed."
