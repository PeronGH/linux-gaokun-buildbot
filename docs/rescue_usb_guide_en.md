English | [中文](rescue_usb_guide_zh.md)

# Gaokun3 Rescue USB

A CLI-only Fedora environment that boots the MateBook E Go from a USB stick. It
ships no installer and no custom scripts: it carries the standard Linux tools,
and the procedures below are ordinary commands you run yourself.

Use it to install Fedora onto the internal disk without Windows and DiskGenius,
or to repair an installation that no longer boots.

## Credentials

**This image has a published password and `sshd` enabled.** While it is running
and joined to a network, anyone on that network can log in as `fedora`.

- The console logs in as `fedora` automatically, and `sudo` asks for nothing
- Over SSH: user `fedora`, password `fedora`
- Root login over SSH is disabled
- SSH host keys are generated per stick on first boot, not baked into the image

Do not leave a rescue boot unattended on a network you do not trust.

## 1. Write the stick

```bash
zstd -d gaokun3-rescue.img.zst -o gaokun3-rescue.img
sudo dd if=gaokun3-rescue.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Any stick of 8 GB or more is worth using: the root partition and filesystem grow
to fill it on first boot, which leaves room to download a Fedora image onto the
stick itself.

## 2. Boot it

1. Press F2 at startup and set Secure Boot to Disable, then save and reboot.
2. Boot the USB stick. The stick boots through the removable path
   (`\EFI\BOOT\BOOTAA64.EFI`), so it does not touch the internal disk's boot
   configuration in any way.
3. The console is rotated upright, uses a large font, and is already logged in
   as `fedora`.

To work over SSH instead of through the console:

```bash
nmtui                 # connect to Wi-Fi; there is no wired NIC on this device
ip -4 addr show       # the address is also printed above the login prompt
```

Then `ssh fedora@<address>` from another machine. Run long operations under
`tmux` so they survive a dropped connection.

Closing the lid does not suspend this environment, so a long write is safe.

## 3. Install Fedora onto the internal disk

Get the image. Release assets are split when they exceed 2 GiB:

```bash
cat fedora-44-gaokun3.img.zst.part-* > fedora-44-gaokun3.img.zst
zstd -d fedora-44-gaokun3.img.zst -o fedora-44-gaokun3.img
sudo losetup -fP --show fedora-44-gaokun3.img   # e.g. /dev/loop0
lsblk /dev/loop0                                 # p1 = ESP, p2 = btrfs rootfs
```

### Make room

Shrinking the Windows partition from Windows Disk Management first is the safe
route, and it can be done while Windows is running. If you shrink it from here
instead, `ntfsresize` shrinks the filesystem and `sgdisk` then has to move the
partition end to match — this is the one destructive step in this guide.

Create the target partition in the free space:

```bash
sudo sgdisk -n 0:0:0 -t 0:8300 -c 0:rootfs /dev/nvme0n1
sudo partprobe /dev/nvme0n1
lsblk /dev/nvme0n1
```

The new partition must be at least as large as `/dev/loop0p2`.

### Copy the root filesystem

```bash
sudo dd if=/dev/loop0p2 of=/dev/nvme0n1p5 bs=4M status=progress conv=fsync
sudo mount /dev/nvme0n1p5 /mnt
sudo btrfs filesystem resize max /mnt
sudo umount /mnt
```

`dd` carries the image's filesystem UUID over, so the kernel command line in the
image's boot entry already points at the right filesystem.

### Merge the ESP

Windows and Fedora share the one ESP. Back up the existing boot loader, then
copy the image's ESP over it — without `--delete`, so `EFI/Microsoft` survives
and `systemd-boot` picks Windows up automatically.

```bash
sudo mkdir -p /mnt/esp /mnt/img-esp
sudo mount /dev/nvme0n1p1 /mnt/esp
sudo mount /dev/loop0p1 /mnt/img-esp
sudo cp /mnt/esp/EFI/BOOT/BOOTAA64.EFI /mnt/esp/EFI/BOOT/BOOTAA64.EFI.bak
sudo rsync -a /mnt/img-esp/ /mnt/esp/
sudo umount /mnt/img-esp
```

### Point the installation at its real partitions

The ESP is the internal disk's, not the image's, so its UUID differs from the
one in the image's `/etc/fstab`. Fix it in the target, then regenerate the boot
entry from the target's own tooling:

```bash
sudo mount -o subvol=root /dev/nvme0n1p5 /mnt/target
sudo mount -o subvol=home /dev/nvme0n1p5 /mnt/target/home
sudo mount /dev/nvme0n1p1 /mnt/target/boot/efi

blkid -s UUID -o value /dev/nvme0n1p1    # ESP  -> /boot/efi line in fstab
blkid -s UUID -o value /dev/nvme0n1p5    # root -> / and /home lines, and cmdline
sudo vim /mnt/target/etc/fstab
sudo vim /mnt/target/etc/kernel/cmdline  # root=UUID=... must match

sudo arch-chroot /mnt/target
```

Inside the chroot, with `<kernel-release>` as printed by `ls /usr/lib/modules`:

```bash
kernel-install --entry-token=os-id --make-entry-directory=yes add \
  <kernel-release> /boot/vmlinuz-<kernel-release>
bootctl --no-variables --esp-path=/boot/efi install
restorecon -R /etc /boot
exit
```

Regenerating the entry is what makes this reliable: it writes the kernel command
line, the initrd and the device tree path from the values that are actually true
on this disk. Nothing has to be made to match the image by hand.

Unmount everything and reboot. `systemd-boot` should offer Fedora and Windows.

## 4. Repair an installation that will not boot

```bash
sudo mount -o subvol=root /dev/nvme0n1p5 /mnt/target
sudo mount /dev/nvme0n1p1 /mnt/target/boot/efi
sudo arch-chroot /mnt/target
```

From there, the usual repairs are the target's own commands:

- Rebuild the initramfs: `dracut --force --kver <kernel-release>`
- Rebuild the boot entry: `kernel-install --entry-token=os-id add ...` as above
- Reinstall the boot loader: `bootctl --no-variables --esp-path=/boot/efi install`
- Reset a password: `passwd <user>`
- Relabel after an SELinux mishap: `fixfiles -F onboot`

To hand the machine back to Windows, restore the backup instead:

```bash
sudo mount /dev/nvme0n1p1 /mnt/esp
sudo cp /mnt/esp/EFI/BOOT/BOOTAA64.EFI.bak /mnt/esp/EFI/BOOT/BOOTAA64.EFI
```

## Notes

- The kernel command line carries `efi=noruntime`, so EFI variables are not
  writable: use `bootctl --no-variables` and expect `efibootmgr` to fail. Boot
  order is decided by the removable path `\EFI\BOOT\BOOTAA64.EFI`, which is why
  the merge step above overwrites it.
- SELinux runs permissive here so that policy can never be what blocks a repair.
  The target's own policy is unaffected.
- The EL2 payloads (`slbounceaa64.efi`, `qebspilaa64.efi`, `tcblaunch.exe`) are
  in `/usr/share/gaokun-el2/` for copying onto a target ESP by hand. See
  [el2_kvm_guide_en.md](el2_kvm_guide_en.md). The rescue environment does not
  boot at EL2 itself.
- `systemd-boot`'s entry editor is enabled, so a kernel command line can be
  edited at the boot menu — `selinux=0` included.
- Anything missing is one `dnf install` away once Wi-Fi is up.
