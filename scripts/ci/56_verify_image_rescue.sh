#!/usr/bin/env bash
set -euo pipefail

# Asserts the properties of the rescue image that are easy to break silently and
# expensive to discover on the device: a stick that cannot boot, a stick that
# shares one SSH identity with every other stick, or a stick that never grows.

: "${WORKDIR:?missing WORKDIR}"
: "${IMAGE_FILE:?missing IMAGE_FILE}"

KREL="$(cat "$WORKDIR/kernel-release.txt")"
ENTRY_TOKEN=gaokun-rescue

LOOP="$(sudo losetup --show -fP "$IMAGE_FILE")"
MNT=/mnt/ego-rescue-verify
cleanup() {
  set +e
  sudo umount "$MNT/dev/pts" 2>/dev/null || true
  sudo umount "$MNT/boot/efi" 2>/dev/null || true
  sudo umount "$MNT/dev" 2>/dev/null || true
  sudo umount "$MNT/proc" 2>/dev/null || true
  sudo umount "$MNT" 2>/dev/null || true
  sudo losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

sudo mkdir -p "$MNT"
sudo mount "${LOOP}p2" "$MNT"
sudo mount "${LOOP}p1" "$MNT/boot/efi"
sudo mount --bind /dev "$MNT/dev"
sudo mount --bind /dev/pts "$MNT/dev/pts"
sudo mount -t proc proc "$MNT/proc"

fail() {
  echo "rescue image check failed: $1" >&2
  exit 1
}

# Baked-in host keys would give every rescue stick the same SSH identity.
if [[ -n "$(sudo find "$MNT/etc/ssh" -name 'ssh_host_*' -print -quit)" ]]; then
  fail "SSH host keys are present in the image"
fi

sudo grep -q '^fedora:' "$MNT/etc/passwd" || fail "no fedora user"
sudo grep -qE '^fedora:\$' "$MNT/etc/shadow" || fail "fedora user has no password hash"
sudo grep -qE '^wheel:.*\bfedora\b' "$MNT/etc/group" || fail "fedora user is not in wheel"

# -L, not -e: the wants symlink is absolute into the image's /usr, which does
# not resolve from the host this check runs on.
for unit in sshd.service NetworkManager.service; do
  sudo test -L "$MNT/etc/systemd/system/multi-user.target.wants/$unit" \
    || fail "$unit is not enabled"
done

entry="$MNT/boot/efi/loader/entries/${ENTRY_TOKEN}-${KREL}.conf"
sudo test -f "$entry" || fail "missing boot entry ${ENTRY_TOKEN}-${KREL}.conf"
sudo test -f "$MNT/boot/efi/EFI/BOOT/BOOTAA64.EFI" || fail "missing removable boot loader"

for key in linux initrd devicetree; do
  target="$(sudo awk -v k="$key" '$1 == k { print $2 }' "$entry")"
  [[ -n "$target" ]] || fail "boot entry has no $key line"
  sudo test -f "$MNT/boot/efi/$target" || fail "boot entry $key points at missing $target"
done

# The only silent one of the three: autologin and passwordless sudo announce
# themselves on the first boot, a zram swap device does not.
sudo test ! -e "$MNT/usr/lib/systemd/zram-generator.conf" || fail "zram is configured"
sudo test -f "$MNT/etc/sudoers.d/10-gaokun-rescue" || fail "no passwordless sudo"
sudo test -f "$MNT/etc/systemd/system/getty@tty1.service.d/10-autologin.conf" \
  || fail "no console autologin"

sudo test ! -s "$MNT/etc/machine-id" || fail "machine-id is not empty"
sudo grep -qE '^UUID=\S+\s+/\s+ext4\s+\S*x-systemd\.growfs' "$MNT/etc/fstab" \
  || fail "root fstab entry does not request growfs"

# lsinitrd comes from the image's own dracut, so this runs inside the image.
initrd_contents="$(sudo chroot "$MNT" lsinitrd "/boot/initramfs-${KREL}.img")"
for want in nvme usb-storage uas systemd-repart; do
  grep -q "$want" <<<"$initrd_contents" || fail "initramfs is missing $want"
done
grep -q 'etc/repart.d/50-root.conf' <<<"$initrd_contents" \
  || fail "initramfs is missing the repart definition"

echo "rescue image checks passed"
