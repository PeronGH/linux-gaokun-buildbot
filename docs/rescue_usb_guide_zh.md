[English](rescue_usb_guide_en.md) | 中文

# Gaokun3 救援 U 盘

一个纯命令行的 Fedora 环境，可以从 U 盘启动 MateBook E Go。它不包含任何安装器或
自制脚本，只带齐标准的 Linux 工具；下面的步骤都是你自己执行的普通命令。

用途：不依赖 Windows 和 DiskGenius，把 Fedora 装到内置硬盘；或者修复已经无法启动
的系统。

## 账号与密码

**该镜像使用公开的密码，并且默认启用 `sshd`。** 只要它在运行并接入了网络，同一网络
上的任何人都可以用 `fedora` 登录。

- 控制台会自动以 `fedora` 登录，`sudo` 不需要密码
- SSH 登录：用户 `fedora`，密码 `fedora`
- 禁止 root 通过 SSH 登录
- SSH 主机密钥在首次启动时按 U 盘生成，不会被打包进镜像

不要把正在运行的救援环境留在不可信的网络上无人看管。

## 一、写入 U 盘

```bash
zstd -d gaokun3-rescue.img.zst -o gaokun3-rescue.img
sudo dd if=gaokun3-rescue.img of=/dev/sdX bs=4M status=progress conv=fsync
```

建议使用 8 GB 以上的 U 盘：根分区和文件系统会在首次启动时扩展到整盘，这样才有空间
把 Fedora 镜像直接下载到 U 盘上。

## 二、启动

1. 开机按 F2，把 Secure Boot 设为 Disable，保存并重启。
2. 从 U 盘启动。U 盘走的是可移动设备路径（`\EFI\BOOT\BOOTAA64.EFI`），完全不会改动
   内置硬盘上的引导配置。
3. 控制台已经旋转为正向、使用大号字体，并且已经以 `fedora` 登录。

如果想通过 SSH 操作而不是使用控制台：

```bash
nmtui                 # 连接 Wi-Fi；本机没有有线网卡
ip -4 addr show       # 地址同时也显示在登录提示上方
```

然后在另一台机器上 `ssh fedora@<地址>`。耗时较长的操作请放在 `tmux` 里执行，避免
断线中断。

合盖不会让该环境进入睡眠，因此长时间写入是安全的。

## 三、把 Fedora 装到内置硬盘

先取得镜像。发布文件超过 2 GiB 时会被分卷：

```bash
cat fedora-44-gaokun3.img.zst.part-* > fedora-44-gaokun3.img.zst
zstd -d fedora-44-gaokun3.img.zst -o fedora-44-gaokun3.img
sudo losetup -fP --show fedora-44-gaokun3.img   # 例如 /dev/loop0
lsblk /dev/loop0                                 # p1 = ESP，p2 = btrfs rootfs
```

### 腾出空间

推荐先在 Windows 的“磁盘管理”里压缩 Windows 分区，这一步可以在 Windows 运行时完成，
也更安全。如果一定要在这里压缩，则需要用 `ntfsresize` 缩小文件系统，再用 `sgdisk`
相应地移动分区末尾——这是本文中唯一具有破坏性的步骤。

在空闲空间中建立目标分区：

```bash
sudo sgdisk -n 0:0:0 -t 0:8300 -c 0:rootfs /dev/nvme0n1
sudo partprobe /dev/nvme0n1
lsblk /dev/nvme0n1
```

新分区不能小于 `/dev/loop0p2`。

### 复制根文件系统

```bash
sudo dd if=/dev/loop0p2 of=/dev/nvme0n1p5 bs=4M status=progress conv=fsync
sudo mount /dev/nvme0n1p5 /mnt
sudo btrfs filesystem resize max /mnt
sudo umount /mnt
```

`dd` 会一并复制镜像里的文件系统 UUID，因此镜像引导项中的内核命令行本来就指向正确的
文件系统。

### 合并 ESP

Windows 和 Fedora 共用同一个 ESP。先备份现有的引导程序，再把镜像的 ESP 覆盖上去；
不要加 `--delete`，这样 `EFI/Microsoft` 会被保留，`systemd-boot` 也能自动识别到
Windows。

```bash
sudo mkdir -p /mnt/esp /mnt/img-esp
sudo mount /dev/nvme0n1p1 /mnt/esp
sudo mount /dev/loop0p1 /mnt/img-esp
sudo cp /mnt/esp/EFI/BOOT/BOOTAA64.EFI /mnt/esp/EFI/BOOT/BOOTAA64.EFI.bak
sudo rsync -a /mnt/img-esp/ /mnt/esp/
sudo umount /mnt/img-esp
```

### 让系统指向真正的分区

这里的 ESP 是内置硬盘上的，不是镜像里的，UUID 与镜像 `/etc/fstab` 中的不同。先在目标
系统里改正，再用目标系统自己的工具重新生成引导项：

```bash
sudo mount -o subvol=root /dev/nvme0n1p5 /mnt/target
sudo mount -o subvol=home /dev/nvme0n1p5 /mnt/target/home
sudo mount /dev/nvme0n1p1 /mnt/target/boot/efi

blkid -s UUID -o value /dev/nvme0n1p1    # ESP  -> fstab 中的 /boot/efi 行
blkid -s UUID -o value /dev/nvme0n1p5    # root -> / 与 /home 行，以及 cmdline
sudo vim /mnt/target/etc/fstab
sudo vim /mnt/target/etc/kernel/cmdline  # root=UUID=... 必须一致

sudo arch-chroot /mnt/target
```

进入 chroot 后，`<kernel-release>` 取 `ls /usr/lib/modules` 的输出：

```bash
kernel-install --entry-token=os-id --make-entry-directory=yes add \
  <kernel-release> /boot/vmlinuz-<kernel-release>
bootctl --no-variables --esp-path=/boot/efi install
restorecon -R /etc /boot
exit
```

重新生成引导项正是这套流程可靠的原因：内核命令行、initrd 和设备树路径都由这块磁盘上
真实的值写出，不需要手工去凑得和镜像一致。

卸载全部挂载点并重启，`systemd-boot` 应当同时列出 Fedora 和 Windows。

## 四、修复无法启动的系统

```bash
sudo mount -o subvol=root /dev/nvme0n1p5 /mnt/target
sudo mount /dev/nvme0n1p1 /mnt/target/boot/efi
sudo arch-chroot /mnt/target
```

之后常见的修复都是目标系统自己的命令：

- 重建 initramfs：`dracut --force --kver <kernel-release>`
- 重建引导项：如上的 `kernel-install --entry-token=os-id add ...`
- 重装引导程序：`bootctl --no-variables --esp-path=/boot/efi install`
- 重置密码：`passwd <用户名>`
- SELinux 出问题后重新打标签：`fixfiles -F onboot`

如果想把机器交还给 Windows，恢复之前的备份即可：

```bash
sudo mount /dev/nvme0n1p1 /mnt/esp
sudo cp /mnt/esp/EFI/BOOT/BOOTAA64.EFI.bak /mnt/esp/EFI/BOOT/BOOTAA64.EFI
```

## 说明

- 内核命令行包含 `efi=noruntime`，因此 EFI 变量不可写：请使用 `bootctl
  --no-variables`，`efibootmgr` 会失败。启动顺序由可移动路径
  `\EFI\BOOT\BOOTAA64.EFI` 决定，这也是上面要覆盖它的原因。
- 本环境的 SELinux 为 permissive，避免策略成为阻断修复的原因；目标系统的策略不受
  影响。
- EL2 相关文件（`slbounceaa64.efi`、`qebspilaa64.efi`、`tcblaunch.exe`）放在
  `/usr/share/gaokun-el2/`，可以手工复制到目标 ESP，参见
  [el2_kvm_guide_zh.md](el2_kvm_guide_zh.md)。救援环境本身不在 EL2 下运行。
- `systemd-boot` 的引导项编辑器是开启的，可以在启动菜单里临时修改内核命令行，包括
  加上 `selinux=0`。
- 连上 Wi-Fi 之后，缺什么工具 `dnf install` 一下即可。
