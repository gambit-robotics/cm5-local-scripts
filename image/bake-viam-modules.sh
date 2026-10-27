#!/usr/bin/env bash
set -euo pipefail

ROOTFS=""
PLATFORM="linux/arm64"

usage() {
    cat <<'EOF'
Usage: image/bake-viam-modules.sh --rootfs PATH

Bakes the linux/arm64 registry modules of the provisioning fragment in the
rootfs's /etc/viam-defaults.json, and of the fragments it nests, where
viam-server keeps them, and lists them in /etc/gambit/viam-modules.txt. On
first boot viam-server finds them synced and downloads only modules whose
version moved after the build.

Needs the viam CLI and jq. It logs in with VIAM_KEY_ID and VIAM_KEY_VALUE
when they are set, and otherwise uses the existing viam CLI login (under sudo,
the invoking user's).
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootfs) ROOTFS="${2:-}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$ROOTFS" ]] || die "--rootfs is required"
command -v viam >/dev/null || die "the viam CLI is required"
command -v jq >/dev/null || die "jq is required"
fragment="$(jq -r '.network_configuration.fragment_id // empty' "$ROOTFS/etc/viam-defaults.json")"
[[ -n "$fragment" ]] || die "$ROOTFS/etc/viam-defaults.json has no network_configuration.fragment_id"

module_root="$ROOTFS/root/.viam/packages/data/module"
manifest="$ROOTFS/etc/gambit/viam-modules.txt"

download_dir="$(mktemp -d)"
trap 'rmdir "$download_dir" 2>/dev/null || true' EXIT
viam_cli() { viam "$@" </dev/null; }
if [[ -n "${VIAM_KEY_ID:-}" && -n "${VIAM_KEY_VALUE:-}" ]]; then
    # The CLI keeps its login under VIAM_HOME; a throwaway one leaves the
    # builder's own login alone.
    VIAM_HOME="$(mktemp -d)"
    export VIAM_HOME
    trap 'viam logout >/dev/null 2>&1 || true; rmdir "$VIAM_HOME" "$download_dir" 2>/dev/null || true' EXIT
    viam_cli login api-key --key-id "$VIAM_KEY_ID" --key "$VIAM_KEY_VALUE" >/dev/null
elif ! viam_cli whoami >/dev/null 2>&1 && [[ -n "${SUDO_USER:-}" ]]; then
    VIAM_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.viam"
    export VIAM_HOME
fi
viam_cli whoami >/dev/null 2>&1 || die "no Viam login: run 'viam login', or set VIAM_KEY_ID and VIAM_KEY_VALUE"

# Prints "<module_id> <version>" for each registry module of a fragment and the
# fragments it nests. Packages stay out: gcloud-creds holds a service account
# key, and the ml_model packages track "latest", which viam-server never
# re-resolves, so a baked copy would pin units to the model of the build day.
fragment_modules() {
    local json child
    json="$(viam_cli fragment get --fragment "$1")" || return
    jq -r '.modules[]? | select(.type == "registry") | "\(.module_id) \(.version // "latest")"' <<<"$json" || return
    jq -r '.packages[]? | "Not baking package \(.name) (\(.type) \(.version // "latest"))"' <<<"$json" >&2
    for child in $(jq -r '.fragments[]? | .id? // .' <<<"$json"); do
        fragment_modules "$child" || return
    done
}

# Resolves a fragment version the way the cloud does for a linux/arm64 unit:
# "latest" is the newest release, "latest-with-prerelease" also counts -rc
# versions. The CLI lists versions newest first.
resolve_version() {
    local id="$1" spec="$2" version
    case "$spec" in
        latest-with-prerelease)
            version="$(viam_cli module versions --id "$id" --latest | awk -v p="$PLATFORM" '$1 == p { print $2 }')" ;;
        latest)
            version="$(viam_cli module versions --id "$id" | awk -v p="$PLATFORM (" '$1 !~ /-/ && index($0, p) { print $1; exit }')" ;;
        *) version="$spec" ;;
    esac
    [[ -n "$version" ]] || die "$id has no $PLATFORM build for version $spec"
    echo "$version"
}

# A module's package ID names its owner org by UUID, and viam-server names the
# module's directory after it, whatever org the unit is in. A wrong UUID fails
# the download rather than baking a copy viam-server would not use.
owner_org() {
    case "$1" in
        viam) echo e76d1b3b-0468-4efd-bb7f-fb1d2b352fcb ;;
        erh) echo c2ba7a2c-e229-484c-b99a-5873631f4ea8 ;;
        gambit-robotics) echo 33604ab0-737c-4481-baa2-b526ccb00362 ;;
        *-*-*-*-*) echo "$1" ;;
        *) die "no owner org ID for module namespace '$1'; add it to owner_org" ;;
    esac
}

install -d -m 0700 "$ROOTFS/root/.viam" "$ROOTFS/root/.viam/packages" "$ROOTFS/root/.viam/packages/data" "$module_root"
install -d -m 0755 "$(dirname "$manifest")"
printf '# Viam modules baked from fragment %s: <package_id> <version>\n' "$fragment" > "$manifest"

modules="$(fragment_modules "$fragment" | sort -u)" || die "could not read fragment $fragment"
[[ -n "$modules" ]] || die "fragment $fragment configures no registry modules"

echo "Baking Viam modules of fragment $fragment"
while read -r id spec; do
    name="${id#*:}"
    org="$(owner_org "${id%%:*}")"
    version="$(resolve_version "$id" "$spec")"
    full="$version-${PLATFORM/\//-}"
    # config.PackageConfig.SanitizedName: "/" and "." become "-" and "_".
    dir="$module_root/$org-$name-${full//./_}"
    printf '%s/%s %s\n' "$org" "$name" "$full" >> "$manifest"
    if [[ -f "$dir.status.json" ]]; then
        echo "  $id $version: already baked"
        continue
    fi
    echo "  $id $version"
    viam_cli module download --id "$org:$name" --version "$version" --platform "$PLATFORM" --destination "$download_dir" >/dev/null
    tarball="$download_dir/$full/$org-$name.tar.gz"
    install -d -m 0700 "$dir"
    tar -xzf "$tarball" -C "$dir" --no-same-owner
    rm -f "$tarball"
    rmdir "$download_dir/$full"
    # The status file viam-server writes after a download; it skips a module
    # whose file names the same package and version with sync_status done.
    cat > "$dir.status.json" <<EOF
{
  "package_id": "$org/$name",
  "version": "$full",
  "modified_time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "sync_status": "done",
  "tarball_checksum": ""
}
EOF
done <<<"$modules"
