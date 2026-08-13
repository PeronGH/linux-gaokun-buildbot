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
UUID=${EFI_UUID}   /boot/efi vfat   umask=0077,shortname=winnt,nofail,x-systemd.device-timeout=10s  0  2
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
# Fedora's own image defaults, held until the user picks in Settings. Anything
# left unset here is asked for on tty1, before gdm, on the first boot.
systemd-firstboot --locale=en_US.UTF-8 --keymap=us --timezone=UTC

mkdir -p /var/lib/AccountsService/users
cat > /var/lib/AccountsService/users/gdm <<'EOF'
[User]
SystemAccount=true
EOF

systemctl enable gdm NetworkManager patch-nvm-bdaddr.service

# The Workstation working group has openssh-server disabled by default, while
# Fedora's general preset enables it, so say so explicitly.
systemctl disable sshd.service

cat > /etc/dracut.conf.d/matebook.conf <<'MODEOF'
hostonly="no"
add_drivers+=" btrfs nvme phy-qcom-qmp-pcie phy-qcom-qmp-combo phy-qcom-qmp-usb phy-qcom-snps-femto-v2 usb-storage uas typec pci-pwrctrl-pwrseq ath11k ath11k_pci i2c-hid-of "
MODEOF

install -d /etc/kernel
cat > /etc/kernel/install.conf <<'EOF'
layout=bls
EOF

# The --entry-token=os-id below only governs the calls made here. Recording it
# makes it survive: without this file, kernel-install resolves "auto" against the
# machine id, which exists by the time the device installs a kernel of its own,
# and a package upgrade would write a second set of entries under a name
# loader.conf does not point at.
. /etc/os-release
printf '%s\n' "$ID" > /etc/kernel/entry-token

install -d /etc/kernel/install.d
ln -sf /dev/null /etc/kernel/install.d/51-dracut-rescue.install

# The boot is verbose, and plymouth is disabled outright rather than just left
# without a theme: with no rhgb/splash it still starts and draws its own details
# view through DRM, which ignores fbcon=rotate:1. Only the kernel's own console
# comes out upright on this portrait panel.
cat > /etc/kernel/cmdline <<EOF
root=UUID=$ROOT_UUID rootflags=subvol=root clk_ignore_unused pd_ignore_unused arm64.nopauth pcie_aspm.policy=powersupersave efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 plymouth.enable=0
EOF

cat > /etc/kernel/devicetree <<'EOF'
qcom/sc8280xp-huawei-gaokun3.dtb
EOF

# Generated only so the tools below have one to work with. It is reset again at
# the end of this script, since a machine-id baked into an image would be shared
# by every device flashed from it.
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

# The editor is what makes the cmdline escape hatches reachable from the device
# itself, selinux=0 below among them, instead of needing another machine to
# mount the ESP.
cat > /boot/efi/loader/loader.conf <<EOF
default fedora-${KREL}.conf
timeout 5
console-mode keep
editor yes
EOF

# The database was written by the builder's rpm; rebuild it with the one the
# device will read it with, so provides resolve and dnf works on first use.
rpm --rebuilddb

# The rootfs is assembled on a host without SELinux, so rpm could not apply
# file contexts. Label it here: an enforcing boot against an unlabeled root
# fails outright. CONFIG_SECURITY_SELINUX_BOOTPARAM=y leaves selinux=0 on the
# kernel cmdline as the escape hatch if this ever goes wrong.
sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
setfiles -e /dev -e /proc -e /sys -e /run \
  -F /etc/selinux/targeted/contexts/files/file_contexts /

# Anything that identifies this build has to go, or every device flashed from
# the image shares it. bootctl install seeded the ESP, and systemd would carry
# the rest forward as its own credentials and entropy.
rm -f /boot/efi/loader/random-seed \
  /var/lib/systemd/random-seed \
  /var/lib/systemd/credential.secret

# Last step, after everything that needed a machine-id has run. "uninitialized"
# rather than empty: only that makes systemd generate a per-device id and treat
# the boot as the first one.
printf 'uninitialized\n' > /etc/machine-id
CHROOT_EOF

if [[ "$BUILD_EL2" == "true" && -n "$KREL_EL2" ]]; then
  install_el2_efi_payloads "$MNT" "$GAOKUN_DIR"
fi

sync

trap - EXIT
cleanup
