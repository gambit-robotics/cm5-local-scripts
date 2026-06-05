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
    cat > "$dir/etc/viam-defaults.json" <<'EOF'
{
  "network_configuration": {
    "manufacturer": "Gambit Robotics",
    "model": "CM5",
    "fragment_id": "f55bd1ed-142c-4232-9ac1-18eba4f99c87",
    "hotspot_interface": "wlan0",
    "hotspot_prefix": "gambit-setup",
    "hotspot_password": "gambitsetup"
  }
}
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

viam_root="$tmp/viam-json"
make_rootfs "$viam_root"
cat > "$viam_root/etc/viam.json" <<'EOF'
{"cloud":{"id":"device-id"}}
EOF
if "$VERIFY" --rootfs "$viam_root" >/dev/null 2>&1; then
    echo "expected baked viam.json fixture to fail" >&2
    exit 1
fi

missing_defaults_root="$tmp/missing-viam-defaults"
make_rootfs "$missing_defaults_root"
rm -f "$missing_defaults_root/etc/viam-defaults.json"
if "$VERIFY" --rootfs "$missing_defaults_root" >/dev/null 2>&1; then
    echo "expected missing viam-defaults fixture to fail" >&2
    exit 1
fi

viam_defaults_root="$tmp/secret-viam-defaults"
make_rootfs "$viam_defaults_root"
cat > "$viam_defaults_root/etc/viam-defaults.json" <<'EOF'
{"cloud":{"secret":"default-secret"}}
EOF
if "$VERIFY" --rootfs "$viam_defaults_root" >/dev/null 2>&1; then
    echo "expected viam-defaults secret fixture to fail" >&2
    exit 1
fi

bad_hotspot_root="$tmp/bad-hotspot"
make_rootfs "$bad_hotspot_root"
sed -i.bak 's/"gambit-setup"/"viam-setup"/' "$bad_hotspot_root/etc/viam-defaults.json"
rm -f "$bad_hotspot_root/etc/viam-defaults.json.bak"
if "$VERIFY" --rootfs "$bad_hotspot_root" >/dev/null 2>&1; then
    echo "expected bad viam-defaults hotspot fixture to fail" >&2
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

gssapi_root="$tmp/gssapi"
make_rootfs "$gssapi_root"
mkdir -p "$gssapi_root/etc/ssh"
cat > "$gssapi_root/etc/ssh/ssh_config" <<'EOF'
#   GSSAPIKeyExchange no
EOF
"$VERIFY" --rootfs "$gssapi_root" >/dev/null

chromium_key_root="$tmp/chromium-key"
make_rootfs "$chromium_key_root"
mkdir -p "$chromium_key_root/etc/chromium.d"
cat > "$chromium_key_root/etc/chromium.d/apikeys" <<'EOF'
export GOOGLE_API_KEY="AIzaSyCkfPOPZXDKNn8hhgu3JrA62wIgC93d44k"
EOF
if "$VERIFY" --rootfs "$chromium_key_root" >/dev/null 2>&1; then
    echo "expected chromium API key fixture to fail" >&2
    exit 1
fi

echo "verify-rootfs tests passed."
