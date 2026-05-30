#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RELEASE=""
ARTIFACT=""
ROOTFS=""
BUCKET="${R2_BUCKET:-gambit-device-images}"
PREFIX="${R2_PREFIX:-device-images/cm5}"
ENDPOINT_URL="${R2_ENDPOINT_URL:-}"
EXPIRES_IN="${R2_SIGNED_URL_EXPIRES_IN:-604800}"
PRINT_URLS=0
DRY_RUN=0
KEEP_STAGE=0
STAGE_DIR=""

usage() {
    cat <<'EOF'
Usage: image/publish-r2.sh --release NAME --artifact PATH [options]

Options:
  --release NAME          Immutable release name, e.g. 2026-06-03-assembler-rc1.
  --artifact PATH         Built image artifact, normally .img.xz.
  --rootfs PATH           Optional mounted rootfs to verify before publishing.
  --bucket NAME           R2 bucket name (default: $R2_BUCKET or gambit-device-images).
  --prefix PREFIX         Object prefix (default: $R2_PREFIX or device-images/cm5).
  --endpoint-url URL      R2 S3 endpoint (default: https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com).
  --expires-in SECONDS    Signed URL lifetime when --print-urls is set (default: 604800).
  --print-urls            Print presigned download URLs after upload.
  --stage-dir PATH        Keep staged release files in PATH instead of a temp dir.
  --keep-stage            Keep temp staging directory after script exits.
  --dry-run               Stage and print planned uploads without calling R2.
  --help                  Show this help.

Required environment for upload:
  R2_ACCOUNT_ID or R2_ENDPOINT_URL
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY

The bucket must remain private. This script never stores credentials in the repo
or image artifact.
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

sha256_file() {
    local path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        die "sha256sum or shasum is required"
    fi
}

object_exists() {
    local key="$1"
    aws s3api head-object \
        --bucket "$BUCKET" \
        --key "$key" \
        --endpoint-url "$ENDPOINT_URL" >/dev/null 2>&1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) RELEASE="${2:-}"; shift 2 ;;
        --artifact) ARTIFACT="${2:-}"; shift 2 ;;
        --rootfs) ROOTFS="${2:-}"; shift 2 ;;
        --bucket) BUCKET="${2:-}"; shift 2 ;;
        --prefix) PREFIX="${2:-}"; shift 2 ;;
        --endpoint-url) ENDPOINT_URL="${2:-}"; shift 2 ;;
        --expires-in) EXPIRES_IN="${2:-}"; shift 2 ;;
        --print-urls) PRINT_URLS=1; shift ;;
        --stage-dir) STAGE_DIR="${2:-}"; KEEP_STAGE=1; shift 2 ;;
        --keep-stage) KEEP_STAGE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n "$RELEASE" ]] || die "--release is required"
[[ -n "$ARTIFACT" ]] || die "--artifact is required"
[[ -f "$ARTIFACT" ]] || die "artifact does not exist: $ARTIFACT"
[[ -n "$BUCKET" ]] || die "--bucket must be non-empty"
[[ -n "$PREFIX" ]] || die "--prefix must be non-empty"
[[ "$RELEASE" =~ ^[A-Za-z0-9._-]+$ ]] || die "--release may contain only letters, numbers, dot, underscore, and dash"
[[ "$EXPIRES_IN" =~ ^[0-9]+$ ]] || die "--expires-in must be seconds"

artifact_name="$(basename "$ARTIFACT")"
[[ "$artifact_name" =~ ^[A-Za-z0-9._+-]+$ ]] || die "artifact basename contains unsupported characters: $artifact_name"

if [[ -n "$ROOTFS" ]]; then
    "$SCRIPT_DIR/verify-rootfs.sh" --rootfs "$ROOTFS"
fi

if [[ -z "$ENDPOINT_URL" && -n "${R2_ACCOUNT_ID:-}" ]]; then
    ENDPOINT_URL="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
    command -v aws >/dev/null 2>&1 || die "aws CLI is required for R2 upload"
    [[ -n "$ENDPOINT_URL" ]] || die "R2_ACCOUNT_ID or --endpoint-url is required"
    [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] || die "AWS_ACCESS_KEY_ID is required"
    [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || die "AWS_SECRET_ACCESS_KEY is required"
    export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
fi

if [[ -z "$STAGE_DIR" ]]; then
    STAGE_DIR="$(mktemp -d)"
fi
if [[ "$KEEP_STAGE" -eq 0 ]]; then
    trap 'rm -rf "$STAGE_DIR"' EXIT
fi
mkdir -p "$STAGE_DIR"

sha="$(sha256_file "$ARTIFACT")"
artifact_size="$(wc -c < "$ARTIFACT" | tr -d ' ')"
created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
cm5_ref="$(git -C "$REPO_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"

staged_artifact="$STAGE_DIR/$artifact_name"
sha_path="$STAGE_DIR/$artifact_name.sha256"
manifest_path="$STAGE_DIR/manifest.json"
flashing_path="$STAGE_DIR/FLASHING.md"
verification_path="$STAGE_DIR/verification.txt"

cp "$ARTIFACT" "$staged_artifact"
printf '%s  %s\n' "$sha" "$artifact_name" > "$sha_path"

cat > "$manifest_path" <<EOF
{
  "name": "gambit-cm5",
  "release": "$RELEASE",
  "artifact": "$artifact_name",
  "sha256": "$sha",
  "size_bytes": $artifact_size,
  "created_at": "$created_at",
  "r2_bucket": "$BUCKET",
  "r2_prefix": "$PREFIX/$RELEASE",
  "cm5_local_scripts_ref": "$cm5_ref",
  "contains_secrets": false
}
EOF

cat > "$flashing_path" <<EOF
# Flashing Gambit CM5 Image

Release: $RELEASE
Artifact: $artifact_name
SHA-256: $sha

1. Download $artifact_name and $artifact_name.sha256.
2. Verify the checksum before flashing:

   sha256sum -c $artifact_name.sha256

3. Flash the image with Raspberry Pi Imager, balenaEtcher, or a verified dd flow.
4. Do not add SSH keys, passwords, Wi-Fi credentials, or device identity to the image.
5. First boot provisioning is handled by Viam/bootstrap.
EOF

{
    echo "release=$RELEASE"
    echo "artifact=$artifact_name"
    echo "sha256=$sha"
    echo "created_at=$created_at"
    echo "cm5_local_scripts_ref=$cm5_ref"
    if [[ -n "$ROOTFS" ]]; then
        echo "rootfs_verification=passed"
    else
        echo "rootfs_verification=not_run_by_publish_script"
    fi
} > "$verification_path"

files=(
    "$staged_artifact"
    "$sha_path"
    "$manifest_path"
    "$flashing_path"
    "$verification_path"
)

echo "Prepared release package:"
echo "  release: $RELEASE"
echo "  bucket:  $BUCKET"
echo "  prefix:  $PREFIX/$RELEASE"
echo "  stage:   $STAGE_DIR"
echo "  sha256:  $sha"

for file in "${files[@]}"; do
    key="$PREFIX/$RELEASE/$(basename "$file")"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "DRY RUN upload: $file -> s3://$BUCKET/$key"
    else
        if object_exists "$key"; then
            die "refusing to overwrite existing R2 object: s3://$BUCKET/$key"
        fi
        aws s3 cp "$file" "s3://$BUCKET/$key" \
            --endpoint-url "$ENDPOINT_URL" \
            --only-show-errors
    fi
done

if [[ "$DRY_RUN" -eq 0 && "$PRINT_URLS" -eq 1 ]]; then
    echo ""
    echo "Signed URLs:"
    for file in "${files[@]}"; do
        key="$PREFIX/$RELEASE/$(basename "$file")"
        url="$(aws s3 presign "s3://$BUCKET/$key" \
            --endpoint-url "$ENDPOINT_URL" \
            --expires-in "$EXPIRES_IN")"
        echo "$(basename "$file"): $url"
    done
fi

echo "R2 publish step complete."
