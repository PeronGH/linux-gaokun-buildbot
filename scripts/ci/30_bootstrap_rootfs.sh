#!/usr/bin/env bash
set -euo pipefail

# Bootstraps an aarch64 Fedora rootfs with dnf --installroot inside a Fedora
# container, then adds the gaokun3 kernel and firmware packages fetched by
# 10_fetch_package_rpms.sh on top of Fedora's own.
#
# PACKAGE_SET carries the groups and packages that define the image variant, so
# the same bootstrap serves the Workstation image and the rescue image.

: "${WORKDIR:?missing WORKDIR}"
: "${ROOTFS_DIR:?missing ROOTFS_DIR}"
: "${PACKAGE_RPMS_DIR:?missing PACKAGE_RPMS_DIR}"
: "${FEDORA_RELEASE:?missing FEDORA_RELEASE}"
: "${PACKAGE_SET:?missing PACKAGE_SET}"

EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
EXCLUDED_PACKAGES="${EXCLUDED_PACKAGES:-}"
INSTALL_LANGS="${INSTALL_LANGS:-all}"
ENABLE_RPMFUSION="${ENABLE_RPMFUSION:-false}"
BUILD_EL2="${BUILD_EL2:-false}"

manifest_path="$PACKAGE_RPMS_DIR/package-manifest.json"
KREL="$(cat "$WORKDIR/kernel-release.txt")"

rpm_names=(
  "$(jq -r '.kernels.standard.packages.kernel' "$manifest_path")"
  "$(jq -r '.kernels.standard.packages.kernel_modules' "$manifest_path")"
  "$(jq -r '.packages.firmware' "$manifest_path")"
)
if [[ "$BUILD_EL2" == "true" ]]; then
  rpm_names+=(
    "$(jq -r '.kernels.el2.packages.kernel' "$manifest_path")"
    "$(jq -r '.kernels.el2.packages.kernel_modules' "$manifest_path")"
  )
fi

rpm_paths=()
for rpm_name in "${rpm_names[@]}"; do
  rpm_paths+=("$PACKAGE_RPMS_DIR/$rpm_name")
done

mkdir -p "$ROOTFS_DIR"

sudo docker run --rm -i \
  -v "$(dirname "$ROOTFS_DIR")":"$(dirname "$ROOTFS_DIR")" \
  -v "$PACKAGE_RPMS_DIR":"$PACKAGE_RPMS_DIR" \
  -w / \
  --user root \
  --privileged \
  -e ROOTFS_DIR="$ROOTFS_DIR" \
  -e FEDORA_RELEASE="$FEDORA_RELEASE" \
  -e PACKAGE_SET="$PACKAGE_SET" \
  -e EXTRA_PACKAGES="$EXTRA_PACKAGES" \
  -e EXCLUDED_PACKAGES="$EXCLUDED_PACKAGES" \
  -e INSTALL_LANGS="$INSTALL_LANGS" \
  -e ENABLE_RPMFUSION="$ENABLE_RPMFUSION" \
  -e RPM_PATHS="${rpm_paths[*]}" \
  "fedora:${FEDORA_RELEASE}" \
  bash -euxo pipefail <<'CONTAINER_EOF'
# The rpm writing the database has to match the one the image will read it with.
# The base container is frozen at release day while the rootfs pulls current
# updates, and a database written under one schema and read under another loses
# its indexes: packages stay listed, but their provides stop resolving and every
# later transaction fails on libc.so.6.
dnf -y update rpm

echo "%_install_langs $INSTALL_LANGS" > /etc/rpm/macros.image-language-conf
sed -i "/tsflags=nodocs/d" /etc/dnf/dnf.conf

mkdir -p "$ROOTFS_DIR"/etc "$ROOTFS_DIR"/proc "$ROOTFS_DIR"/sys "$ROOTFS_DIR"/dev

# rpm chroots into the installroot to run scriptlets, and no package expects to
# be installed into a tree without these. They live and die with this container's
# mount namespace, so the host never sees them and the rootfs is clean to copy.
mount -t proc proc "$ROOTFS_DIR/proc"
mount -t sysfs sys "$ROOTFS_DIR/sys"
mount --bind /dev "$ROOTFS_DIR/dev"
trap 'umount -l "$ROOTFS_DIR/dev" "$ROOTFS_DIR/sys" "$ROOTFS_DIR/proc"' EXIT

dnf_install() {
  dnf -y --installroot="$ROOTFS_DIR" --releasever="$FEDORA_RELEASE" \
    --use-host-config "$@"
}

dnf_install --exclude="$EXCLUDED_PACKAGES" install $PACKAGE_SET $EXTRA_PACKAGES

if [ "$ENABLE_RPMFUSION" = "true" ]; then
  dnf_install install \
    "https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_RELEASE}.noarch.rpm"

  mkdir -p /etc/pki/rpm-gpg
  cp -a "$ROOTFS_DIR/etc/pki/rpm-gpg/." /etc/pki/rpm-gpg/

  dnf_install --setopt=reposdir="$ROOTFS_DIR/etc/yum.repos.d,/etc/yum.repos.d" \
    install libavcodec-freeworld
fi

dnf_install --nogpgcheck install $RPM_PATHS
CONTAINER_EOF

sudo depmod -b "$ROOTFS_DIR" -a "$KREL"
if [[ "$BUILD_EL2" == "true" ]]; then
  sudo depmod -b "$ROOTFS_DIR" -a "$(cat "$WORKDIR/kernel-release-el2.txt")"
fi
