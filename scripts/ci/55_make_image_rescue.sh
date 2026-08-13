#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common_image.sh
. "$(dirname "$0")/lib/common_image.sh"

: "${GAOKUN_DIR:?missing GAOKUN_DIR}"
: "${WORKDIR:?missing WORKDIR}"
: "${ROOTFS_DIR:?missing ROOTFS_DIR}"
: "${IMAGE_FILE:?missing IMAGE_FILE}"
: "${IMAGE_SIZE:?missing IMAGE_SIZE}"
: "${FEDORA_RELEASE:?missing FEDORA_RELEASE}"

KREL="$(cat "$WORKDIR/kernel-release.txt")"
ENTRY_TOKEN=gaokun-rescue

EFI_END_MIB=513
truncate -s "$IMAGE_SIZE" "$IMAGE_FILE"
parted -s "$IMAGE_FILE" mklabel gpt
parted -s "$IMAGE_FILE" mkpart EFI fat32 1MiB "${EFI_END_MIB}MiB"
parted -s "$IMAGE_FILE" set 1 esp on
parted -s "$IMAGE_FILE" mkpart rootfs ext4 "${EFI_END_MIB}MiB" 100%

LOOP="$(sudo losetup --show -fP "$IMAGE_FILE")"
sudo mkfs.vfat -F32 -n RESCUE-EFI "${LOOP}p1"
sudo mkfs.ext4 -F -L gaokun-rescue "${LOOP}p2"

EFI_UUID="$(sudo blkid -s UUID -o value "${LOOP}p1")"
ROOT_UUID="$(sudo blkid -s UUID -o value "${LOOP}p2")"

MNT=/mnt/ego-rescue
cleanup() {
  set +e
  sudo umount "$MNT/dev/pts" 2>/dev/null || true
  sudo umount "$MNT/boot/efi" 2>/dev/null || true
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
sudo mkdir -p "$MNT/boot/efi"
sudo mount "${LOOP}p1" "$MNT/boot/efi"

sudo rsync -aHAX "$ROOTFS_DIR/" "$MNT/"
install_module_config "$MNT" "$GAOKUN_DIR" rescue

# Kept as plain files so a target ESP can be populated by hand from the rescue
# environment. Nothing here is booted by the rescue image itself.
for payload in slbounceaa64.efi qebspilaa64.efi tcblaunch.exe; do
  sudo install -Dm644 "$GAOKUN_DIR/tools/el2/$payload" \
    "$MNT/usr/share/gaokun-el2/$payload"
done

# x-systemd.growfs finishes what systemd-repart starts: repart grows the
# partition to the size of whatever USB stick this was written to, and growfs
# then grows the filesystem into it.
sudo tee "$MNT/etc/fstab" >/dev/null <<EOF
UUID=${ROOT_UUID}  /         ext4  defaults,x-systemd.growfs                     0  1
UUID=${EFI_UUID}   /boot/efi vfat  defaults,nofail,x-systemd.device-timeout=10s  0  2
EOF

sudo mount --bind /dev "$MNT/dev"
sudo mount --bind /dev/pts "$MNT/dev/pts"
sudo mount -t proc proc "$MNT/proc"
sudo mount -t sysfs sys "$MNT/sys"
sudo mount -t tmpfs tmpfs "$MNT/run"

sudo chroot "$MNT" /usr/bin/env \
  KREL="$KREL" \
  ROOT_UUID="$ROOT_UUID" \
  ENTRY_TOKEN="$ENTRY_TOKEN" \
  FEDORA_RELEASE="$FEDORA_RELEASE" \
  /bin/bash -euxo pipefail <<'CHROOT_EOF'
echo "gaokun-rescue" > /etc/hostname

cat > /etc/locale.conf <<'EOF'
LANG=en_US.UTF-8
EOF

# The panel is 2560x1600 and the console is rotated into portrait, where the
# default 8x16 font is unreadable. This console is the whole interface.
cat > /etc/vconsole.conf <<'EOF'
KEYMAP=us
FONT=ter-v32b
EOF

# A published password on a downloadable image: anyone on the same network can
# reach this machine while it is running. That is the trade for being able to
# drive a repair over SSH instead of through the rotated console.
useradd --create-home --groups wheel --comment "Rescue user" fedora
echo 'fedora:fedora' | chpasswd

# sshd takes the first value it obtains for a keyword, so this sorts ahead of
# Fedora's own 50-redhat.conf.
cat > /etc/ssh/sshd_config.d/10-gaokun-rescue.conf <<'EOF'
PasswordAuthentication yes
PermitRootLogin no
EOF

# No host keys are generated here. sshd-keygen@.service makes a per-stick set on
# first boot, so every rescue USB does not share one identity.
systemctl enable sshd.service NetworkManager.service

cat > /etc/issue <<EOF
Gaokun3 rescue environment - Fedora ${FEDORA_RELEASE} - \l

  login: fedora    password: fedora
  address: \4

EOF

# A flash or a filesystem check must survive the lid being closed.
install -d /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/10-gaokun-rescue.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
EOF

# Type= matches the GPT type parted writes for an ext4 partition. Naming the
# discoverable "root" type instead would match nothing here, and repart would
# add a second partition rather than grow this one.
install -d /etc/repart.d
cat > /etc/repart.d/50-root.conf <<'EOF'
[Partition]
Type=linux-generic
EOF

# hostonly=no because the stick has to boot on a device it was not built on.
# usb-storage and uas carry the root filesystem, nvme reaches the disk being
# repaired. systemd-repart runs from the initrd, before the root filesystem is
# mounted, so growfs sees the grown partition on the same boot; install_items
# puts the definition above where that early run can find it.
cat > /etc/dracut.conf.d/matebook.conf <<'MODEOF'
hostonly="no"
add_drivers+=" btrfs nvme phy-qcom-qmp-pcie phy-qcom-qmp-combo phy-qcom-qmp-usb phy-qcom-snps-femto-v2 usb-storage uas typec pci-pwrctrl-pwrseq ath11k ath11k_pci i2c-hid-of "
add_dracutmodules+=" systemd-repart "
install_items+=" /etc/repart.d/50-root.conf "
MODEOF

install -d /etc/kernel
cat > /etc/kernel/install.conf <<'EOF'
layout=bls
EOF

install -d /etc/kernel/install.d
ln -sf /dev/null /etc/kernel/install.d/51-dracut-rescue.install

cat > /etc/kernel/cmdline <<EOF
root=UUID=$ROOT_UUID rootwait clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 plymouth.enable=0
EOF

cat > /etc/kernel/devicetree <<'EOF'
qcom/sc8280xp-huawei-gaokun3.dtb
EOF

dracut --force --kver "$KREL"

# Needed by the tools below, and emptied again at the end.
rm -f /etc/machine-id
systemd-machine-id-setup

bootctl --no-variables --esp-path=/boot/efi install

# A token of its own: a rescue stick and a target install must never write the
# same entry name if their ESPs are ever both mounted. The remove clears
# whatever the kernel RPM's %posttrans wrote while the rootfs had no ESP.
kernel-install --entry-token="$ENTRY_TOKEN" remove "$KREL" || true
kernel-install --verbose --make-entry-directory=yes --entry-token="$ENTRY_TOKEN" add \
  "$KREL" "/boot/vmlinuz-$KREL"

cat > /boot/efi/loader/loader.conf <<EOF
default ${ENTRY_TOKEN}-${KREL}.conf
timeout 3
console-mode keep
editor yes
EOF

# The rootfs was assembled on a host without SELinux, so it carries no labels.
# It is relabelled so sshd and systemd behave predictably and enforcing stays
# one edit away, but it runs permissive: policy must never be what stops a
# repair.
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
setfiles -e /dev -e /proc -e /sys -e /run \
  -F /etc/selinux/targeted/contexts/files/file_contexts /

# Last, so every stick generates its own on first boot.
: > /etc/machine-id
CHROOT_EOF

sync

trap - EXIT
cleanup
