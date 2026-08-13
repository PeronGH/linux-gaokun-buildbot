[English](matebook_ego_build_guide_fedora44_en.md) | 中文

# Huawei MateBook E Go 2023 Fedora 44 手动构建指南

> **目标机型**：Huawei MateBook E Go 2023（代号 `gaokun3`）  
> **平台**：高通骁龙 8cx Gen3（`SC8280XP`）  
> **目标系统**：Fedora 44 GNOME，systemd-boot 启动，Btrfs 根文件系统  
> **推荐宿主机**：Fedora 或其他基于 RPM/DNF 的发行版  
> **仓库假设**：本文默认你当前仓库位于 `~/gaokun/linux-gaokun-buildbot`

**WSL2 建议切换到支持 `vfat`、`btrfs` 等文件系统更完整的内核，例如：<https://github.com/Nevuly/WSL2-Linux-Kernel-Rolling/releases>**

---

## 准备说明

本文使用项目内已有内容，不需要额外获取设备专属仓库：

- `patches/`
- `defconfig/`
- `dts/`
- `tools/`
- `firmware/`

如果宿主机是 arm64，可直接原生构建。  
如果宿主机是 x86_64，请自行准备可用的 aarch64 交叉工具链，并在编译内核时额外设置 `CROSS_COMPILE`。

---

## 第一步：准备工作目录

安装基础依赖（Fedora arm64 宿主机示例）：

```bash
sudo dnf install gcc make bison flex bc openssl-devel elfutils-libelf-devel \
    ncurses-devel dwarves git parted dosfstools btrfs-progs curl python3 rsync ccache
```

准备源码与工作目录：

```bash
mkdir -p ~/gaokun/matebook-build-fedora

cd ~/gaokun
# 获取指定版本的 Linux 主线源码
if [ ! -d "mainline-linux" ]; then
    git clone --depth 1 --branch v7.2-rc2 \
        https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git \
        mainline-linux
fi
```

设置环境变量：

```bash
export GAOKUN_DIR=~/gaokun/linux-gaokun-buildbot
export WORKDIR=~/gaokun/matebook-build-fedora
export KERN_SRC=~/gaokun/mainline-linux
export KERN_OUT=~/gaokun/kernel-out
export KERN_OUT_EL2=~/gaokun/kernel-out-el2
export FW_REPO=$GAOKUN_DIR/firmware
export ROOTFS_DIR=$WORKDIR/rootfs
export IMAGE_FILE=$WORKDIR/fedora-44-gaokun3.img
export CCACHE_DIR=$WORKDIR/.ccache
export CCACHE_BASEDIR=$WORKDIR
export CCACHE_NOHASHDIR=true
export CCACHE_COMPILERCHECK=content
if [ -d /usr/lib64/ccache ]; then
    export PATH=/usr/lib64/ccache:$PATH
elif [ -d /usr/lib/ccache ]; then
    export PATH=/usr/lib/ccache:$PATH
fi
```

---

## 第二步：编译内核

先编译标准内核。

```bash
cd $KERN_SRC

# 应用项目内置补丁
git config user.name "local builder"
git config user.email "builder@example.com"
git am $GAOKUN_DIR/patches/upstream/*.patch
git am $GAOKUN_DIR/patches/others/*.patch
cp $GAOKUN_DIR/dts/*.dts $GAOKUN_DIR/dts/*.dtsi arch/arm64/boot/dts/qcom/
cp $GAOKUN_DIR/defconfig/gaokun3_defconfig arch/arm64/configs/
git add -A && git commit -m "arm64: gaokun3: import local dts and defconfig"

mkdir -p $KERN_OUT
ccache -z

# 根据 patch 后的 gaokun3_defconfig 生成配置，再补齐新内核默认选项
make O=$KERN_OUT ARCH=arm64 gaokun3_defconfig
make O=$KERN_OUT ARCH=arm64 olddefconfig
make O=$KERN_OUT ARCH=arm64 -j$(nproc)
make O=$KERN_OUT ARCH=arm64 modules_prepare

KREL=$(cat $KERN_OUT/include/config/kernel.release)
echo $KREL
KREL_EL2=""
ccache -s
```

如果你需要 EL2，建议先把标准内核安装到 rootfs，或者先单独备份好 `Image`、`dtb`、`modules` 产物，然后在同一套源码上继续构建带 `-gaokun3-el2` 后缀的内核，EL2 产物单独放到另一个输出目录：

```bash
rm -rf $KERN_OUT_EL2
git -C $KERN_SRC apply --index $GAOKUN_DIR/patches/el2/*.patch
git -C $KERN_SRC commit -m "Apply EL2 patches"
ccache -z

make -C $KERN_SRC O=$KERN_OUT_EL2 ARCH=arm64 gaokun3_defconfig
$KERN_SRC/scripts/config --file $KERN_OUT_EL2/.config --set-str LOCALVERSION "-gaokun3-el2"
make -C $KERN_SRC O=$KERN_OUT_EL2 ARCH=arm64 olddefconfig
make -C $KERN_SRC O=$KERN_OUT_EL2 ARCH=arm64 -j$(nproc)
make -C $KERN_SRC O=$KERN_OUT_EL2 ARCH=arm64 modules_prepare

KREL_EL2=$(cat $KERN_OUT_EL2/include/config/kernel.release)
echo $KREL_EL2
ccache -s
```

---

## 第三步：构建 RootFS

使用 `dnf --installroot` 安装 Fedora 44 GNOME Desktop，并补充启动、网络、输入法和常用工具。

> 若宿主机是 Ubuntu 等非 Fedora 系统，可先安装 `dnf`，然后继续使用 `--installroot` 方式构建。

```bash
mkdir -p $ROOTFS_DIR

sudo dnf -y install glibc-langpack-en

# 第一步先安装基础系统、locale 和 langpacks
sudo dnf --installroot=$ROOTFS_DIR --releasever=44 --forcearch=aarch64 --use-host-config -y \
    --exclude=gnome-boxes,gnome-connections,snapshot,gnome-weather,gnome-contacts,gnome-maps,simple-scan,gnome-clocks,gnome-calculator,gnome-calendar \
    install \
    @core @standard \
    systemd-boot-unsigned alsa-ucm \
    glibc-langpack-en langpacks-en \
    google-noto-color-emoji-fonts google-noto-emoji-fonts \
    i2c-tools alsa-utils pipewire-utils

sudo mkdir -p $ROOTFS_DIR/etc
sudo tee $ROOTFS_DIR/etc/locale.conf > /dev/null <<EOF
LANG=en_US.UTF-8
EOF

# 第二步再安装桌面环境和应用，能更稳定地把对应语言的翻译子包一起拉进 rootfs
sudo dnf --installroot=$ROOTFS_DIR --releasever=44 --forcearch=aarch64 --use-host-config -y \
    --exclude=gnome-boxes,gnome-connections,snapshot,gnome-weather,gnome-contacts,gnome-maps,simple-scan,gnome-clocks,gnome-calculator,gnome-calendar,amd-gpu-firmware,intel-gpu-firmware,linux-firmware,nvidia-gpu-firmware,toolbox,unoconv,mediawriter \
    install \
    @gnome-desktop @workstation-product \
    gnome-tweaks gnome-extensions-app telnet mpv v4l-utils vim nano ripgrep git htop fastfetch screen firefox

# 安装 RPMFusion 并添加 libavcodec-freeworld（硬解视频编码支持）
sudo dnf --installroot=$ROOTFS_DIR --releasever=44 --forcearch=aarch64 --use-host-config -y \
    install \
    https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-44.noarch.rpm

sudo mkdir -p /etc/pki/rpm-gpg
sudo cp -a $ROOTFS_DIR/etc/pki/rpm-gpg/. /etc/pki/rpm-gpg/

sudo dnf --installroot=$ROOTFS_DIR --releasever=44 --forcearch=aarch64 --use-host-config -y \
    --setopt=reposdir="$ROOTFS_DIR/etc/yum.repos.d,/etc/yum.repos.d" \
    install \
    libavcodec-freeworld
```

安装内核、模块、固件和本地工具：

```bash
cd $KERN_SRC

KREL=$(cat $KERN_OUT/include/config/kernel.release)
echo $KREL

sudo make O=$KERN_OUT ARCH=arm64 INSTALL_MOD_PATH=$ROOTFS_DIR modules_install
sudo rm -f $ROOTFS_DIR/lib/modules/$KREL/{build,source}

# 安装 kernel image
sudo mkdir -p $ROOTFS_DIR/boot
sudo cp $KERN_OUT/arch/arm64/boot/Image \
    $ROOTFS_DIR/boot/vmlinuz-$KREL

# Fedora 的 kernel-install 会从这里查找 DTB
sudo mkdir -p $ROOTFS_DIR/usr/lib/modules/$KREL/dtb/qcom
sudo cp $KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb \
    $ROOTFS_DIR/usr/lib/modules/$KREL/dtb/qcom/

# 额外保留一份 /boot 下的 DTB，方便后续切换到 GRUB 等其他引导器
sudo mkdir -p $ROOTFS_DIR/boot/dtb-$KREL/qcom
sudo cp $KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb \
    $ROOTFS_DIR/boot/dtb-$KREL/qcom/

# 如果需要 EL2，再安装第二套 EL2 内核与 DTB
if [ -n "$KREL_EL2" ]; then
    sudo make -C $KERN_SRC O=$KERN_OUT_EL2 ARCH=arm64 INSTALL_MOD_PATH=$ROOTFS_DIR modules_install
    sudo rm -f $ROOTFS_DIR/lib/modules/$KREL_EL2/{build,source}
    sudo cp $KERN_OUT_EL2/arch/arm64/boot/Image \
        $ROOTFS_DIR/boot/vmlinuz-$KREL_EL2
    sudo mkdir -p $ROOTFS_DIR/usr/lib/modules/$KREL_EL2/dtb/qcom
    sudo cp $KERN_OUT_EL2/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3-el2.dtb \
        $ROOTFS_DIR/usr/lib/modules/$KREL_EL2/dtb/qcom/
    sudo mkdir -p $ROOTFS_DIR/boot/dtb-$KREL_EL2/qcom
    sudo cp $KERN_OUT_EL2/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3-el2.dtb \
        $ROOTFS_DIR/boot/dtb-$KREL_EL2/qcom/
fi

# 直接复制项目内置的最小固件集
sudo mkdir -p $ROOTFS_DIR/lib/firmware
sudo cp -r $FW_REPO/. $ROOTFS_DIR/lib/firmware/

# 安装项目内的设备专属脚本与服务
sudo mkdir -p $ROOTFS_DIR/usr/local/bin
sudo mkdir -p $ROOTFS_DIR/usr/local/lib/gaokun-touchscreen-tuner
sudo mkdir -p $ROOTFS_DIR/etc/systemd/system
sudo mkdir -p $ROOTFS_DIR/usr/share/alsa/ucm2/Qualcomm/sc8280xp
sudo mkdir -p $ROOTFS_DIR/usr/share/applications

# 触摸屏调参工具和桌面入口
sudo cp $GAOKUN_DIR/tools/touchscreen-tuner/touchscreen-tune \
    $ROOTFS_DIR/usr/local/bin/touchscreen-tune
sudo cp $GAOKUN_DIR/tools/touchscreen-tuner/tune.py \
    $ROOTFS_DIR/usr/local/lib/gaokun-touchscreen-tuner/tune.py
sudo cp $GAOKUN_DIR/tools/touchscreen-tuner/tune-icon.svg \
    $ROOTFS_DIR/usr/local/lib/gaokun-touchscreen-tuner/tune-icon.svg
sudo cp $GAOKUN_DIR/tools/touchscreen-tuner/touchscreen-tune.desktop \
    $ROOTFS_DIR/usr/share/applications/touchscreen-tune.desktop
sudo chmod +x $ROOTFS_DIR/usr/local/bin/touchscreen-tune

# 蓝牙地址修补脚本和服务
sudo cp $GAOKUN_DIR/tools/bluetooth/patch-nvm-bdaddr.py \
    $ROOTFS_DIR/usr/local/bin/
sudo cp $GAOKUN_DIR/tools/bluetooth/patch-nvm-bdaddr.service \
    $ROOTFS_DIR/etc/systemd/system/
sudo chmod +x $ROOTFS_DIR/usr/local/bin/patch-nvm-bdaddr.py

# 音频 UCM 配置
sudo cp $GAOKUN_DIR/tools/audio/sc8280xp.conf \
    $ROOTFS_DIR/usr/share/alsa/ucm2/Qualcomm/sc8280xp/

# 复用 CI 镜像流水线里的共享资源，其中包括 etc/xdg/monitors.xml 里的屏幕布局
sudo cp -a $GAOKUN_DIR/tools/image-assets/etc/. \
    $ROOTFS_DIR/etc/

# bluetooth.conf 现在会同时加载 btqca 和 uhid，避免 BLE HoG 鼠标/键盘配对后立刻断开。
# patch-nvm-bdaddr.service 会在 bluetooth.service 之前修补 qca/wcnhpnv21g.bin 中的 BDADDR。
```

---

## 第四步：制作可启动镜像

### 1. 创建镜像和分区

```bash
cd $WORKDIR
truncate -s 12G $IMAGE_FILE

parted -s $IMAGE_FILE mklabel gpt
parted -s $IMAGE_FILE mkpart EFI fat32 1MiB 1025MiB
parted -s $IMAGE_FILE set 1 esp on
parted -s $IMAGE_FILE mkpart rootfs btrfs 1025MiB 100%

LOOP=$(sudo losetup --show -fP $IMAGE_FILE)
sudo mkfs.vfat -F32 -n EFI ${LOOP}p1
sudo mkfs.btrfs -f -L rootfs ${LOOP}p2

EFI_UUID=$(sudo blkid -s UUID -o value ${LOOP}p1)
ROOT_UUID=$(sudo blkid -s UUID -o value ${LOOP}p2)
```

### 2. 创建 Btrfs 子卷并同步 RootFS

```bash
sudo mkdir -p /mnt/ego-fedora

# 创建 Fedora 的子卷布局：root 用于 /，home 用于 /home
sudo mount ${LOOP}p2 /mnt/ego-fedora
sudo btrfs subvolume create /mnt/ego-fedora/root
sudo btrfs subvolume create /mnt/ego-fedora/home
sudo umount /mnt/ego-fedora

# 挂载子卷并准备 EFI 分区
sudo mount -o subvol=root ${LOOP}p2 /mnt/ego-fedora
sudo mkdir -p /mnt/ego-fedora/home
sudo mount -o subvol=home ${LOOP}p2 /mnt/ego-fedora/home
sudo mkdir -p /mnt/ego-fedora/boot/efi
sudo mount ${LOOP}p1 /mnt/ego-fedora/boot/efi

sudo rsync -aHAX --info=progress2 --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' $ROOTFS_DIR/ /mnt/ego-fedora/

sudo tee /mnt/ego-fedora/etc/fstab > /dev/null <<EOF
UUID=${ROOT_UUID}  /         btrfs  subvol=root,compress=zstd:1  0  0
UUID=${ROOT_UUID}  /home     btrfs  subvol=home,compress=zstd:1  0  0
UUID=${EFI_UUID}   /boot/efi vfat   defaults,nofail,x-systemd.device-timeout=10s  0  2
EOF
```

### 3. chroot 初始化并生成 systemd-boot / BLS

```bash
cleanup_mounts() {
    sudo umount /mnt/ego-fedora/dev/pts 2>/dev/null || true
    sudo umount /mnt/ego-fedora/boot/efi 2>/dev/null || true
    sudo umount /mnt/ego-fedora/var 2>/dev/null || true
    sudo umount /mnt/ego-fedora/home 2>/dev/null || true
    sudo umount /mnt/ego-fedora/dev 2>/dev/null || true
    sudo umount /mnt/ego-fedora/proc 2>/dev/null || true
    sudo umount /mnt/ego-fedora/sys 2>/dev/null || true
    sudo umount /mnt/ego-fedora/run 2>/dev/null || true
    sudo umount /mnt/ego-fedora 2>/dev/null || true
}

sudo mount --bind /dev /mnt/ego-fedora/dev
sudo mount --bind /dev/pts /mnt/ego-fedora/dev/pts
sudo mount -t proc proc /mnt/ego-fedora/proc
sudo mount -t sysfs sys /mnt/ego-fedora/sys
sudo mount -t tmpfs tmpfs /mnt/ego-fedora/run

sudo chroot /mnt/ego-fedora /bin/bash
```

在 chroot 中执行：

```bash
cat > /etc/dracut.conf.d/matebook.conf <<EOF
hostonly="no"
add_drivers+=" btrfs nvme phy-qcom-qmp-pcie phy-qcom-qmp-combo phy-qcom-qmp-usb phy-qcom-snps-femto-v2 usb-storage uas typec pci-pwrctrl-pwrseq ath11k ath11k_pci i2c-hid-of lpasscc_sc8280xp snd-soc-sc8280xp pinctrl_sc8280xp_lpass_lpi "
install_items+=" /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn /lib/firmware/qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin "
EOF

install -d /etc/kernel
cat > /etc/kernel/install.conf <<EOF
layout=bls
EOF

install -d /etc/kernel/install.d
ln -sf /dev/null /etc/kernel/install.d/51-dracut-rescue.install

cat > /etc/kernel/cmdline <<EOF
root=UUID=${ROOT_UUID} rootflags=subvol=root clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=1 pcie_aspm.policy=powersupersave efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 psi=1 plymouth.enable=0
EOF

cat > /etc/kernel/devicetree <<EOF
qcom/sc8280xp-huawei-gaokun3.dtb
EOF

systemctl enable patch-nvm-bdaddr.service

dracut --force --kver $KREL
if [ -n "$KREL_EL2" ]; then
    dracut --force --kver $KREL_EL2
fi

rm -f /etc/machine-id
systemd-machine-id-setup

bootctl --no-variables --esp-path=/boot/efi install

kernel-install --make-entry-directory=yes --entry-token=os-id add \
    $KREL /boot/vmlinuz-$KREL

if [ -n "$KREL_EL2" ]; then
    mkdir -p /boot/efi/EFI/systemd/drivers
    mkdir -p /boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3

    EL2_CONF_ROOT=$(mktemp -d)
    cat > $EL2_CONF_ROOT/install.conf <<EOF
layout=bls
EOF
    cat > $EL2_CONF_ROOT/cmdline <<EOF
root=UUID=${ROOT_UUID} rootflags=subvol=root clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=1 pcie_aspm.policy=powersupersave modprobe.blacklist=simpledrm efi=noruntime fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 psi=1 plymouth.enable=0
EOF
    cat > $EL2_CONF_ROOT/devicetree <<EOF
qcom/sc8280xp-huawei-gaokun3-el2.dtb
EOF
    KERNEL_INSTALL_CONF_ROOT=$EL2_CONF_ROOT \
        kernel-install --make-entry-directory=yes --entry-token=os-id add \
        $KREL_EL2 /boot/vmlinuz-$KREL_EL2
    rm -rf $EL2_CONF_ROOT

    cp $GAOKUN_DIR/tools/el2/slbounceaa64.efi /boot/efi/EFI/systemd/drivers/
    cp $GAOKUN_DIR/tools/el2/qebspilaa64.efi /boot/efi/EFI/systemd/drivers/
    cp $GAOKUN_DIR/tools/el2/tcblaunch.exe /boot/efi/
    cp /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn \
       /boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3/
    cp /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn \
       /boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3/
    cp /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn \
       /boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3/
fi

cat > /boot/efi/loader/loader.conf <<EOF
default fedora-${KREL}.conf
timeout 5
console-mode keep
editor yes
EOF

# Empty it again, so every device generates its own on first boot
: > /etc/machine-id

exit
```

说明：

- 这里不再手工维护 `loader/entries/*.conf` 和 `gaokun3/fedora/...` 目录，而是让 `kernel-install` 生成标准 BLS Type #1 布局。
- 这里使用 `--entry-token=os-id`，因此条目名为 `/boot/efi/loader/entries/fedora-<kernel-release>.conf`。不能使用 machine-id：镜像中的 `/etc/machine-id` 是空的，每台设备首次启动时各自生成，否则按构建时 id 命名的条目会被孤立。
- Fedora 44 的 `90-loaderentry.install` 会从 `/usr/lib/modules/<kernel-release>/dtb/` 查找设备树，所以 DTB 必须放到这个标准路径里。
- Fedora 默认的 `51-dracut-rescue.install` 会额外生成 `0-rescue` 启动项，但这个救援项默认不带 `devicetree`，在 gaokun3 上不可用，因此这里显式将其禁用。

### 触屏驱动鸣谢

- [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux)：本仓库直接集成的 `himax_hx83121a_spi` 触屏驱动与调参算法的主要上游来源。
- [awarson2233/EGoTouchRev](https://github.com/awarson2233/EGoTouchRev)：EGoTouchRev-Linux 所参考的 Windows 侧触控算法项目，也是本方案触摸算法调参与行为的重要上游来源。

### 4. 收尾清理

```bash
sync
cleanup_mounts
sudo losetup -d $LOOP
```

---

## 第五步：双系统和 EL2 说明

- 双系统覆盖 EFI 的方式请参考 [dual_boot_guide_zh.md](dual_boot_guide_zh.md)
- 如果在本指南中同时构建了 `-gaokun3-el2` 内核变体，产出的镜像就已经具备 EL2 支持。
- 有关实现细节、启动链结构和排障说明，请参考 [el2_kvm_guide_zh.md](el2_kvm_guide_zh.md)
