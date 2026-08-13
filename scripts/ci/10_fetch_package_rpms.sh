#!/usr/bin/env bash
set -euo pipefail

# Resolves the gaokun3 RPM release matching KERNEL_TAG and downloads its kernel
# and firmware packages. PACKAGE_RELEASE_TAG may be set by the caller when the
# packages were just rebuilt in the same run; otherwise the newest release
# matching the tag and EL2 profile is used.

: "${GITHUB_TOKEN:?missing GITHUB_TOKEN}"
: "${GITHUB_REPOSITORY:?missing GITHUB_REPOSITORY}"
: "${WORKDIR:?missing WORKDIR}"
: "${PACKAGE_RPMS_DIR:?missing PACKAGE_RPMS_DIR}"
: "${KERNEL_TAG:?missing KERNEL_TAG}"

BUILD_EL2="${BUILD_EL2:-false}"
PACKAGE_RELEASE_TAG="${PACKAGE_RELEASE_TAG:-}"

api() {
  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$@"
}

mkdir -p "$WORKDIR" "$PACKAGE_RPMS_DIR"

if [[ -z "$PACKAGE_RELEASE_TAG" ]]; then
  safe_kernel_tag="${KERNEL_TAG//\//-}"
  safe_kernel_tag="${safe_kernel_tag//[^A-Za-z0-9._-]/-}"
  profile="std"
  if [[ "$BUILD_EL2" == "true" ]]; then
    profile="std-el2"
  fi
  prefix="gaokun3-rpms-${safe_kernel_tag}-${profile}-"

  releases_json="$WORKDIR/releases.json"
  api "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
    -o "$releases_json"

  PACKAGE_RELEASE_TAG="$(jq -r --arg prefix "$prefix" \
    '.[] | select(.tag_name | startswith($prefix)) | .tag_name' \
    "$releases_json" | head -n 1)"

  if [[ -z "$PACKAGE_RELEASE_TAG" ]]; then
    echo "no package release found for prefix ${prefix}" >&2
    exit 1
  fi
fi

release_json="$WORKDIR/package-release.json"
api "https://api.github.com/repos/${GITHUB_REPOSITORY}/releases/tags/${PACKAGE_RELEASE_TAG}" \
  -o "$release_json"

download_asset() {
  local name="$1"
  local url

  url="$(jq -r --arg name "$name" \
    '.assets[] | select(.name == $name) | .url' "$release_json")"

  if [[ -z "$url" || "$url" == "null" ]]; then
    echo "missing asset ${name} in release ${PACKAGE_RELEASE_TAG}" >&2
    exit 1
  fi

  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/octet-stream" \
    "$url" \
    -o "$PACKAGE_RPMS_DIR/$name"
}

download_asset "package-manifest.json"
manifest_path="$PACKAGE_RPMS_DIR/package-manifest.json"

manifest_kernel_tag="$(jq -r '.kernel_tag' "$manifest_path")"
if [[ "$manifest_kernel_tag" != "$KERNEL_TAG" ]]; then
  echo "package release kernel tag mismatch: expected ${KERNEL_TAG}, got ${manifest_kernel_tag}" >&2
  exit 1
fi

manifest_build_el2="$(jq -r '.build_el2' "$manifest_path")"
if [[ "$BUILD_EL2" == "true" && "$manifest_build_el2" != "true" ]]; then
  echo "package release ${PACKAGE_RELEASE_TAG} does not contain EL2 packages" >&2
  exit 1
fi

asset_names=(
  "$(jq -r '.kernels.standard.packages.kernel' "$manifest_path")"
  "$(jq -r '.kernels.standard.packages.kernel_modules' "$manifest_path")"
  "$(jq -r '.packages.firmware' "$manifest_path")"
)

jq -r '.kernels.standard.release' "$manifest_path" > "$WORKDIR/kernel-release.txt"

if [[ "$BUILD_EL2" == "true" ]]; then
  asset_names+=(
    "$(jq -r '.kernels.el2.packages.kernel' "$manifest_path")"
    "$(jq -r '.kernels.el2.packages.kernel_modules' "$manifest_path")"
  )
  jq -r '.kernels.el2.release' "$manifest_path" > "$WORKDIR/kernel-release-el2.txt"
else
  rm -f "$WORKDIR/kernel-release-el2.txt"
fi

for asset_name in "${asset_names[@]}"; do
  download_asset "$asset_name"
done

printf '%s\n' "$PACKAGE_RELEASE_TAG" > "$WORKDIR/package-release-tag.txt"
