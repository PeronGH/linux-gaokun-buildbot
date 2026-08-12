#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common_image.sh
. "$(dirname "$0")/lib/common_image.sh"

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${ROOTFS_DIR:?missing ROOTFS_DIR}"
: "${ARTIFACT_DIR:?missing ARTIFACT_DIR}"
: "${IMAGE_FILE:?missing IMAGE_FILE}"
: "${IMAGE_SIZE:?missing IMAGE_SIZE}"
: "${FEDORA_RELEASE:?missing FEDORA_RELEASE}"

BUILD_EL2="${BUILD_EL2:-false}"
KREL="$(cat "$WORKDIR/kernel-release.txt")"
KREL_EL2=""
if [[ "$BUILD_EL2" == "true" && -f "$WORKDIR/kernel-release-el2.txt" ]]; then
  KREL_EL2="$(cat "$WORKDIR/kernel-release-el2.txt")"
fi

EFI_END_MIB=1025
truncate -s "$IMAGE_SIZE" "$IMAGE_FILE"
parted -s "$IMAGE_FILE" mklabel gpt
parted -s "$IMAGE_FILE" mkpart EFI fat32 1MiB "${EFI_END_MIB}MiB"
parted -s "$IMAGE_FILE" set 1 esp on
parted -s "$IMAGE_FILE" mkpart rootfs btrfs "${EFI_END_MIB}MiB" 100%

LOOP="$(sudo losetup --show -fP "$IMAGE_FILE")"
sudo mkfs.vfat -F32 -n EFI "${LOOP}p1"
sudo mkfs.btrfs -f -L rootfs "${LOOP}p2"

EFI_UUID="$(sudo blkid -s UUID -o value "${LOOP}p1")"
ROOT_UUID="$(sudo blkid -s UUID -o value "${LOOP}p2")"

MNT=/mnt/ego-fedora
cleanup() {
  set +e
  sudo umount "$MNT/dev/pts" 2>/dev/null || true
  sudo umount "$MNT/boot/efi" 2>/dev/null || true
  sudo umount "$MNT/home" 2>/dev/null || true
  sudo umount "$MNT/dev" 2>/dev/null || true
  sudo umount "$MNT/proc" 2>/dev/null || true
  sudo umount "$MNT/sys" 2>/dev/null || true
  sudo umount "$MNT/run" 2>/dev/null || true
  sudo umount "$MNT" 2>/dev/null || true
  sudo losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

sudo mkdir -p "$MNT"
sudo mount "${LOOP}p2" "$MNT"
sudo btrfs subvolume create "$MNT/root"
sudo btrfs subvolume create "$MNT/home"
sudo umount "$MNT"
sudo mount -o subvol=root "${LOOP}p2" "$MNT"
sudo mkdir -p "$MNT/home"
sudo mount -o subvol=home "${LOOP}p2" "$MNT/home"
sudo mkdir -p "$MNT/boot/efi"
sudo mount "${LOOP}p1" "$MNT/boot/efi"

sudo rsync -aHAX "$ROOTFS_DIR/" "$MNT/"
install_common_image_assets "$MNT" "$GAOKUN_DIR"

sudo tee "$MNT/etc/fstab" >/dev/null <<EOF
UUID=${ROOT_UUID}  /         btrfs  subvol=root,compress=zstd:1  0  0
UUID=${ROOT_UUID}  /home     btrfs  subvol=home,compress=zstd:1  0  0
UUID=${EFI_UUID}   /boot/efi vfat   defaults,nofail,x-systemd.device-timeout=10s  0  2
EOF

sudo mount --bind /dev "$MNT/dev"
sudo mount --bind /dev/pts "$MNT/dev/pts"
sudo mount -t proc proc "$MNT/proc"
sudo mount -t sysfs sys "$MNT/sys"
sudo mount -t tmpfs tmpfs "$MNT/run"

sudo chroot "$MNT" /usr/bin/env KREL="$KREL" KREL_EL2="$KREL_EL2" BUILD_EL2="$BUILD_EL2" ROOT_UUID="$ROOT_UUID" /bin/bash -euxo pipefail <<'CHROOT_EOF'
echo "fedora" > /etc/hostname

# No account is created here. gdm runs gnome-initial-setup when no regular user
# exists, so the first boot asks for a name and password the way stock Fedora
# does, instead of shipping a known one.

# dnf must not remove the only kernel that can boot this device:
# protect_running_kernel matches Fedora's package names, not ours.
cat > /etc/dnf/protected.d/kernel-gaokun3.conf <<'EOF'
kernel-gaokun3
EOF

# Fedora's own kernels cannot boot this device, and kernel-install would write
# each one into the 1 GiB ESP. The rootfs does not currently pull any in, so
# this only has to keep a later transaction from doing so.
cat >> /etc/dnf/dnf.conf <<'EOF'
excludepkgs=kernel,kernel-core,kernel-modules,kernel-modules-core
EOF
# A language is a property of whoever ends up using the device, not of the
# device, so do not presume one. en_US.UTF-8 is Fedora's own fallback and is
# only here because something has to be set until the user picks in Settings;
# the language packs for other locales are installed and ready to switch to.
cat > /etc/locale.conf <<'EOF'
LANG=en_US.UTF-8
EOF

mkdir -p /var/lib/AccountsService/users
cat > /var/lib/AccountsService/users/gdm <<'EOF'
[User]
SystemAccount=true
EOF

# The panel is portrait and needs a rotation applied before anyone has logged
# in, so write the layout for the login screen and for accounts created later.
# gdm reads it from its own home; a session reads it from skel.
install -Dm644 /usr/local/share/gaokun/monitors.xml /etc/skel/.config/monitors.xml
install -d -o gdm -g gdm -m 0755 /var/lib/gdm/.config
install -o gdm -g gdm -m 0644 /usr/local/share/gaokun/monitors.xml \
  /var/lib/gdm/.config/monitors.xml

systemctl enable gdm NetworkManager patch-nvm-bdaddr.service || true

# The Workstation working group has openssh-server disabled by default, while
# Fedora's general preset enables it, so say so explicitly.
systemctl disable sshd.service || true

cat > /etc/dracut.conf.d/matebook.conf <<'MODEOF'
hostonly="no"
add_drivers+=" btrfs nvme phy-qcom-qmp-pcie phy-qcom-qmp-combo phy-qcom-qmp-usb phy-qcom-snps-femto-v2 usb-storage uas typec pci-pwrctrl-pwrseq ath11k ath11k_pci i2c-hid-of "
MODEOF

install -d /etc/kernel
cat > /etc/kernel/install.conf <<'EOF'
layout=bls
EOF

install -d /etc/kernel/install.d
ln -sf /dev/null /etc/kernel/install.d/51-dracut-rescue.install

cat > /etc/kernel/cmdline <<EOF
root=UUID=$ROOT_UUID rootflags=subvol=root clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 psi=1 rhgb quiet
EOF

cat > /etc/kernel/devicetree <<'EOF'
qcom/sc8280xp-huawei-gaokun3.dtb
EOF

dracut --force --kver "$KREL"
if [[ "$BUILD_EL2" == "true" && -n "$KREL_EL2" ]]; then
  dracut --force --kver "$KREL_EL2"
fi

# Generated only so the tools below have one to work with. It is emptied again
# at the end of this script, since a machine-id baked into an image would be
# shared by every device flashed from it.
rm -f /etc/machine-id
systemd-machine-id-setup

bootctl --no-variables --esp-path=/boot/efi install

run_kernel_install() {
  local krel="$1"
  local image="$2"
  local dtb="$3"
  local cmdline="$4"
  local conf_root

  conf_root="$(mktemp -d)"
  cat > "$conf_root/install.conf" <<'EOF'
layout=bls
EOF
  printf '%s\n' "$cmdline" > "$conf_root/cmdline"
  printf 'qcom/%s\n' "$dtb" > "$conf_root/devicetree"

  kernel-install --entry-token=os-id remove "$krel" || true
  KERNEL_INSTALL_CONF_ROOT="$conf_root" \
    kernel-install --verbose --make-entry-directory=yes --entry-token=os-id add \
    "$krel" "$image"
  rm -rf "$conf_root"
}

BASE_CMDLINE="$(cat /etc/kernel/cmdline)"
run_kernel_install \
  "$KREL" \
  "/boot/vmlinuz-$KREL" \
  "sc8280xp-huawei-gaokun3.dtb" \
  "$BASE_CMDLINE"

if [[ "$BUILD_EL2" == "true" && -n "$KREL_EL2" ]]; then
  EL2_CMDLINE="${BASE_CMDLINE} modprobe.blacklist=simpledrm"
  run_kernel_install \
    "$KREL_EL2" \
    "/boot/vmlinuz-$KREL_EL2" \
    "sc8280xp-huawei-gaokun3-el2.dtb" \
    "$EL2_CMDLINE"
fi

cat > /boot/efi/loader/loader.conf <<EOF
default fedora-${KREL}.conf
timeout 5
console-mode keep
editor no
EOF

# The rootfs is assembled on a host without SELinux, so rpm could not apply
# file contexts. Label it here: an enforcing boot against an unlabeled root
# fails outright. CONFIG_SECURITY_SELINUX_BOOTPARAM=y leaves selinux=0 on the
# kernel cmdline as the escape hatch if this ever goes wrong.
sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
setfiles -e /dev -e /proc -e /sys -e /run \
  -F /etc/selinux/targeted/contexts/files/file_contexts /

# Last step, after everything that needed a machine-id has run. An empty file
# makes systemd generate a per-device id on first boot and makes
# ConditionFirstBoot fire; a populated one would be cloned to every device.
: > /etc/machine-id
CHROOT_EOF

if [[ "$BUILD_EL2" == "true" && -n "$KREL_EL2" ]]; then
  install_el2_efi_payloads "$MNT" "$GAOKUN_DIR"
fi

sync

trap - EXIT
cleanup
