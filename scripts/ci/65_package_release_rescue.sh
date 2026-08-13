#!/usr/bin/env bash
set -euo pipefail

: "${WORKDIR:?missing WORKDIR}"
: "${ARTIFACT_DIR:?missing ARTIFACT_DIR}"
: "${IMAGE_FILE:?missing IMAGE_FILE}"
: "${FEDORA_RELEASE:?missing FEDORA_RELEASE}"
: "${KERNEL_TAG:?missing KERNEL_TAG}"
: "${PACKAGE_SET:?missing PACKAGE_SET}"

KREL="$(cat "$WORKDIR/kernel-release.txt")"
IMAGE_BASENAME="$(basename "$IMAGE_FILE")"
ZST_NAME="${IMAGE_BASENAME}.zst"
RELEASE_BODY_FILE="$ARTIFACT_DIR/release-body.md"

zstd -T0 -19 "$IMAGE_FILE" -o "$ARTIFACT_DIR/$ZST_NAME"
(cd "$ARTIFACT_DIR" && sha256sum "$ZST_NAME" > SHA256SUMS)

cat > "$RELEASE_BODY_FILE" <<EOF
A CLI-only rescue and installation environment for the Huawei MateBook E Go 2023
(\`gaokun3\`). It boots from a USB stick with the same kernel, device tree and
kernel command line as the Fedora image, and carries the standard Linux tools
needed to partition, write and repair an installation. It ships no installer:
the procedure is in \`docs/rescue_usb_guide_en.md\`.

## Credentials

**This image has a published password and \`sshd\` enabled.** While it is
running and joined to a network, anyone on that network can log in as
\`fedora\`. Do not leave a rescue boot unattended on a network you do not trust.

- The console logs in as \`fedora\` automatically, and \`sudo\` asks for nothing
- Over SSH: user \`fedora\`, password \`fedora\`
- Root login is disabled; SSH host keys are generated per stick on first boot

## Build Information

- Distribution: \`Fedora Linux ${FEDORA_RELEASE}\`
- Kernel Tag: \`${KERNEL_TAG}\`
- Kernel Release: \`${KREL}\`
- Architecture: \`arm64\`
- Root Filesystem: \`ext4\`
- Bootloader: \`systemd-boot\`
- Compressed File: \`${ZST_NAME}\`
- Build Time (UTC): \`$(date -u +"%Y-%m-%dT%H:%M:%SZ")\`

## Rootfs Selection

- Packages: \`${PACKAGE_SET}\`

## Write And Boot

\`\`\`bash
zstd -d ${ZST_NAME} -o ${IMAGE_BASENAME}
sudo dd if=${IMAGE_BASENAME} of=/dev/sdX bs=4M status=progress conv=fsync
\`\`\`

Disable Secure Boot (F2 at startup) and boot the stick. The root partition and
filesystem grow to the size of the stick on first boot, so there is room to
download a Fedora image onto it.
EOF

TAG_NAME="gaokun3-rescue-${KREL}-$(date -u +%Y%m%d%H%M%S)"

echo "$TAG_NAME" > "$WORKDIR/tag-name.txt"
echo "$KREL" > "$WORKDIR/kernel-release-export.txt"
basename "$RELEASE_BODY_FILE" > "$WORKDIR/release-body-file.txt"
