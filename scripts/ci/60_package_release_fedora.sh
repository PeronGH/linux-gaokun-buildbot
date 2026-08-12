#!/usr/bin/env bash
set -euo pipefail

: "${WORKDIR:?missing WORKDIR}"
: "${ARTIFACT_DIR:?missing ARTIFACT_DIR}"
: "${IMAGE_FILE:?missing IMAGE_FILE}"
: "${IMAGE_CHUNK_SIZE:?missing IMAGE_CHUNK_SIZE}"
: "${FEDORA_RELEASE:?missing FEDORA_RELEASE}"
: "${KERNEL_TAG:?missing KERNEL_TAG}"
: "${DESKTOP_ENVIRONMENT:?missing DESKTOP_ENVIRONMENT}"
: "${EXCLUDED_PACKAGES:?missing EXCLUDED_PACKAGES}"
: "${EXTRA_PACKAGES:?missing EXTRA_PACKAGES}"

KREL="$(cat "$WORKDIR/kernel-release.txt")"
BUILD_EL2="${BUILD_EL2:-false}"
EL2_KREL=""
if [[ "$BUILD_EL2" == "true" && -f "$WORKDIR/kernel-release-el2.txt" ]]; then
  EL2_KREL="$(cat "$WORKDIR/kernel-release-el2.txt")"
fi
IMAGE_BASENAME="$(basename "$IMAGE_FILE")"
ZST_FILE="$ARTIFACT_DIR/${IMAGE_BASENAME}.zst"
RELEASE_BODY_FILE="$ARTIFACT_DIR/release-body.md"
SPLIT_THRESHOLD_BYTES=$((2 * 1024 * 1024 * 1024))
EL2_RELEASE_BLOCK=""
EL2_PAYLOAD_BLOCK=""
if [[ "$BUILD_EL2" == "true" && -n "$EL2_KREL" ]]; then
  EL2_RELEASE_BLOCK="$(cat <<EOF
- Optional EL2 Kernel Release: \`${EL2_KREL}\`
EOF
)"
  EL2_PAYLOAD_BLOCK="## EL2 Payload

- Includes systemd-boot EL2 menu entry
- Includes \`slbounceaa64.efi\`, \`qebspilaa64.efi\`, \`tcblaunch.exe\`, and the three DSP firmware blobs in ESP \`/firmware/qcom/sc8280xp/HUAWEI/gaokun3/\`

"
fi

cp "$IMAGE_FILE" "$ARTIFACT_DIR/"
zstd -T0 -19 "$ARTIFACT_DIR/$IMAGE_BASENAME" -o "$ZST_FILE"

if [ "$(stat -c '%s' "$ZST_FILE")" -lt "$SPLIT_THRESHOLD_BYTES" ]; then
  PACKAGE_GLOB="${IMAGE_BASENAME}.zst"
  cat > "$RELEASE_BODY_FILE" <<EOF
## Build Information

- Distribution: \`Fedora Linux ${FEDORA_RELEASE}\`
- Kernel Tag: \`${KERNEL_TAG}\`
- Kernel Release: \`${KREL}\`
- Architecture: \`arm64\`
${EL2_RELEASE_BLOCK}
- Root Filesystem: \`Btrfs (root, home)\`
- Bootloader: \`systemd-boot\`
- Image File: \`${IMAGE_BASENAME}\`
- Compressed File: \`${IMAGE_BASENAME}.zst\`
- Build Time (UTC): \`$(date -u +"%Y-%m-%dT%H:%M:%SZ")\`

## Rootfs Selection

- Desktop Environment: \`${DESKTOP_ENVIRONMENT}\`
- Excluded Packages: \`${EXCLUDED_PACKAGES}\`
- Extra Packages: \`${EXTRA_PACKAGES}\`

## Default Login

- Username: \`user\`
- Password: \`user\`
${EL2_PAYLOAD_BLOCK}
EOF
else
  split -b "$IMAGE_CHUNK_SIZE" -d -a 3 \
    "$ZST_FILE" \
    "$ZST_FILE.part-"
  PACKAGE_GLOB="${IMAGE_BASENAME}.zst.part-*"
  cat > "$RELEASE_BODY_FILE" <<EOF
## Build Information

- Distribution: \`Fedora Linux ${FEDORA_RELEASE}\`
- Kernel Tag: \`${KERNEL_TAG}\`
- Kernel Release: \`${KREL}\`
- Architecture: \`arm64\`
${EL2_RELEASE_BLOCK}
- Root Filesystem: \`Btrfs (root, home)\`
- Bootloader: \`systemd-boot\`
- Image File: \`${IMAGE_BASENAME}\`
- Compressed File: \`${IMAGE_BASENAME}.zst\`
- Build Time (UTC): \`$(date -u +"%Y-%m-%dT%H:%M:%SZ")\`

## Rootfs Selection

- Desktop Environment: \`${DESKTOP_ENVIRONMENT}\`
- Excluded Packages: \`${EXCLUDED_PACKAGES}\`
- Extra Packages: \`${EXTRA_PACKAGES}\`

## Default Login

- Username: \`user\`
- Password: \`user\`

${EL2_PAYLOAD_BLOCK}

## Reassemble And Decompress

\`\`\`bash
cat ${IMAGE_BASENAME}.zst.part-* > ${IMAGE_BASENAME}.zst
zstd -d ${IMAGE_BASENAME}.zst -o ${IMAGE_BASENAME}
\`\`\`
EOF
fi

sudo chown "$(id -u):$(id -g)" "$RELEASE_BODY_FILE"

TAG_NAME="fedora${FEDORA_RELEASE}-${KREL}$(if [[ "$BUILD_EL2" == "true" ]]; then printf -- '-el2'; fi)-$(date -u +%Y%m%d%H%M%S)"

echo "$TAG_NAME" > "$WORKDIR/tag-name.txt"
echo "$KREL" > "$WORKDIR/kernel-release-export.txt"
echo "$PACKAGE_GLOB" > "$WORKDIR/package-glob.txt"
echo "$(basename "$RELEASE_BODY_FILE")" > "$WORKDIR/release-body-file.txt"
