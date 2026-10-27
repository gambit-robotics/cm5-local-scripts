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

Needs the viam CLI, jq, and a Gambit org API key (never a personal login) in
VIAM_KEY_ID and VIAM_KEY_VALUE.
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
[[ -n "${VIAM_KEY_ID:-}" && -n "${VIAM_KEY_VALUE:-}" ]] || die "VIAM_KEY_ID and VIAM_KEY_VALUE must hold a Gambit org API key"
command -v viam >/dev/null || die "the viam CLI is required"
command -v jq >/dev/null || die "jq is required"
fragment="$(jq -r '.network_configuration.fragment_id // empty' "$ROOTFS/etc/viam-defaults.json")"
[[ -n "$fragment" ]] || die "$ROOTFS/etc/viam-defaults.json has no network_configuration.fragment_id"

module_root="$ROOTFS/root/.viam/packages/data/module"
manifest="$ROOTFS/etc/gambit/viam-modules.txt"

# The CLI keeps its login under VIAM_HOME, so the API key never touches the
# operator's own ~/.viam.
cli_home="$(mktemp -d)"
download_dir="$(mktemp -d)"
trap 'VIAM_HOME="$cli_home" viam logout >/dev/null 2>&1 || true; rmdir "$cli_home" "$download_dir" 2>/dev/null || true' EXIT
viam_cli() { VIAM_HOME="$cli_home" viam "$@" </dev/null; }
viam_cli login api-key --key-id "$VIAM_KEY_ID" --key "$VIAM_KEY_VALUE" >/dev/null

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
