[English](../README.md) | 中文

# linux-gaokun-buildbot

面向华为 MateBook E Go 2023（代号 `gaokun3`）、基于高通骁龙 8cx Gen3（`SC8280XP`）平台的 Linux 镜像构建脚本、补丁、内核配置、设备树文件、工具和固件。

镜像流水线现默认使用 `systemd-boot`，并可选构建带 `CONFIG_LOCALVERSION="-gaokun3-el2"` 的第二套 EL2 内核变体。

## 目标

以下目标按优先级排列，冲突时以靠前者为准。

1. **在 MateBook E Go 上获得最佳体验。** 硬件适配优先于其他一切。DTS、内核配置、固件集，以及 `fbcon=rotate:1`、`usbhid.quirks` 等 cmdline 参数都是这台设备所必需的，即使与原版 Fedora 不同也会保留。启用 RPM Fusion 和 `libavcodec-freeworld` 同样出于这个原因：开箱即用地播放媒体。
2. **接近原版 Fedora 的体验。** 基准是 Fedora 官方的 aarch64 Workstation raw 磁盘镜像，即所构建版本对应的 [`releases/<release>/Workstation/aarch64/images/`](https://download.fedoraproject.org/pub/fedora/linux/releases/) 下的 `Fedora-Workstation-Disk-*.aarch64.raw.xz`，不锁定具体版本号。[Fedora 的 Workstation 文档](https://docs.fedoraproject.org/en-US/workstation-docs/) 同样作为基准：Fedora 针对 aarch64 Workstation 的任何说明在这里都适用。在硬件没有强制要求的地方，与之保持一致而非自创方案：Fedora 的 Btrfs 布局（`root` 与 `home` 子卷、`compress=zstd:1`）、SELinux enforcing、不使用免密 `sudo`。它同样决定了我们不做什么：如果那个镜像不预装拼音输入法或某种语言的翻译，我们也不装。任何偏离都应是有意为之，并且值得记录下来。
3. **可以长期日常使用。** 不应比 x86 Fedora 安装更容易被搞坏：`kernel-gaokun3` 受删除保护、排除无法引导本设备的 Fedora 官方内核、安装内核即成为默认启动项。此项特意排在最后，因此不会添加 Fedora 本身没有的额外限制，`dnf system-upgrade` 即使在这里确实有风险也不做拦截。

## 包含内容

### 仓库结构

- `patches/`：内核补丁和设备支持更改
- `defconfig/`：CI/手动构建使用的本地内核配置
- `drivers/`：补丁系列中修改过的驱动源码本地镜像
- `dts/`：补丁系列中修改过的设备树源码本地镜像
- `docs/`：中英文使用/构建指南与平台说明
- `firmware/`：镜像构建使用的最小固件集
- `packaging/`：各发行版内核和固件包的打包模板和元数据
- `tools/`：设备专属辅助脚本、服务文件和 EL2 EFI 载荷
- `scripts/ci/`：工作流构建、镜像创建和打包脚本
- `scripts/local/`：一些可在本地设备上运行的实用脚本

### 软件包产物

软件包流水线会构建并安装专用软件包集：

- **Fedora (RPM)**：`kernel-gaokun3`、`kernel-modules-gaokun3`、`kernel-devel-gaokun3`、`linux-firmware-gaokun3`
- **可选 EL2 变体**：用于第二套 EL2 内核构建的 `*-gaokun3-el2` 软件包集
- Fedora 内核 RPM 现自带匹配的 `dracut.conf.d` 片段，并在 `%posttrans` 中运行 `dracut` + `kernel-install add`，因此安装或升级软件包会自动刷新 initramfs 和 BLS 条目。

### Release 产物

- Fedora 镜像 release 包含压缩后的可安装镜像。
- Gaokun RPM release 包含镜像工作流所使用的独立内核与固件软件包集合。

### 补丁来源

- `upstream/*`, `others/0017`：来自 [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun)，涵盖基础 SC8280XP / gaokun3 使能、显示点亮、EC 挂起恢复、ADSP FastRPC 以及 DSI 稳定性相关改动
- `others/0001`：来自 [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux)，用于在蓝牙地址无效时避免设置 `USE_BDADDR_PROPERTY`
- `others/0002`：本仓库内的本地改动，用于启用 DSC 以及 60 Hz / 120 Hz 切换
- `others/0003`：来自 [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux)，用于加入 Himax HX83121A SPI 触摸屏驱动
- `others/0004`：来自 [TheUnknownThing/linux-gaokun](https://github.com/TheUnknownThing/linux-gaokun)，用于改进 Type-C 路径的 UCSI 处理和模块接线
- `dts/` 与 `defconfig/`：由 `scripts/lib/import_local_sources.sh` 直接复制进内核树，而非以补丁形式携带，因此内核版本升级时不会产生冲突
- **[可选]** `el2/*`：来自 [TravMurav/linux](https://github.com/TravMurav/linux/tree/x13s-6.18-v1.1-cxsd)，用于补齐 EL2 启动路径中的 SMP2P 接管、remoteproc attach/restart 流程、SCM/SHM owner 处理，以及 rpmsg / QRTR / pmic_glink 相关稳定性修复

### Tools 来源

- `tools/audio`、`tools/bluetooth`：来自 [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux)
- `tools/el2/qebspilaa64.efi`：来自 [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)
- `tools/el2/slbounceaa64.efi`：来自 [TravMurav/slbounce](https://github.com/TravMurav/slbounce)
- `tools/touchscreen-tuner`：来自 [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux)，本仓库对其做了 GTK4 GUI 改进

## 启动产物布局

镜像和本地安装工作流现遵循标准 `kernel-install` + BLS 流程，而非手动编写 `systemd-boot` 条目。

- BLS 条目名称和条目目录由 `kernel-install` 配合 `--entry-token=os-id` 生成，即 `loader/entries/fedora-<kernel-release>.conf`。这里特意不用默认的 machine-id：镜像中的 `/etc/machine-id` 为空，每台设备首次启动时各自生成，按构建时 id 命名的条目会被孤立。
- 复制到 ESP 的内核、initrd/initramfs 和 DTB 文件也会由发行版钩子自动放入匹配的 `<entry-token>/<kernel-release>/` 目录。
- 在 `/boot` 中还会保留一份 DTB 的兼容副本，方便用户后续切换到 GRUB。
- Fedora DTB 安装在 `/usr/lib/modules/<kernel-release>/dtb/qcom/` 供 `kernel-install` 使用，另有 `/boot/dtb-<kernel-release>/qcom/` 兼容副本。
- Gaokun3 镜像脚本提供 `/etc/kernel/cmdline` 和 `/etc/kernel/devicetree`，然后调用 `kernel-install add` 填充最终的 BLS 条目。

## 快速开始

- Release：<https://github.com/KawaiiHachimi/linux-gaokun-build/releases>
- 双系统引导指南：[English](dual_boot_guide_en.md) | [中文](dual_boot_guide_zh.md)
- EL2 实现说明：[English](el2_kvm_guide_en.md) | [中文](el2_kvm_guide_zh.md)
- Awesome Gaokun3：：[English](awesome_gaokun3_en.md) | [中文](awesome_gaokun3_zh.md)
- 构建指南 – Fedora 44：[English](matebook_ego_build_guide_fedora44_en.md) | [中文](matebook_ego_build_guide_fedora44_zh.md)

### 语言与输入法

镜像只设置 `LANG=en_US.UTF-8`，不预装任何输入法，与作为基准的 Workstation 镜像一致。
在 GNOME 设置中添加所需语言后，Fedora 会提示安装对应的翻译和输入法。

中文输入有两条都算合理的路线，镜像无法替你选择：

- `fcitx5-chinese-addons` 开箱即用，通常再配合 `fcitx5-pinyin-zhwiki` 词库。
- `fcitx5-rime` 搭配 [rime-ice](https://github.com/iDvel/rime-ice)（雾凇拼音），是比较讲究的
  用户最终的选择，但需要自己配置，而这恰恰是它的意义所在。

## 功能支持

设备硬件工作情况可参考 [right-0903/linux-gaokun 的 `## Feature Support`](https://github.com/right-0903/linux-gaokun?tab=readme-ov-file#feature-support)。

## 参考

- [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun)：内核补丁和设备支持工作的主要来源，附有详细的提交信息和说明。
- [TheUnknownThing/linux-gaokun](https://github.com/TheUnknownThing/linux-gaokun)：内核补丁和设备支持工作的另一个分支，包含触摸屏和 EC 相关的独特提交和说明。
- [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux)：最早修复面板背光问题的仓库，包含一些额外的 Gaokun3 Linux 支持资源和修改。
- [gaokun on AUR](https://aur.archlinux.org/packages?O=0&K=gaokun)：为 Gaokun3 构建的多个 AUR 软件包，包括内核和固件包。
- [chenxuecong2/firmware-huawei-gaokun3](https://github.com/chenxuecong2/firmware-huawei-gaokun3)：Gaokun3 固件集合仓库。
- [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux)：内置 `himax_hx83121a_spi` 内核模块的上游触摸屏驱动和算法仓库。
- [awarson2233/EGoTouchRev](https://github.com/awarson2233/EGoTouchRev)：EGoTouchRev-Linux 参考的 Windows 侧触控算法项目，也是 Gaokun3 触摸屏调参流水线的重要上游参考。
- [TravMurav/slbounce](https://github.com/TravMurav/slbounce)：在 Gaokun3 上启用 EL2 支持和安全启动的 UEFI 应用程序。
- [TravMurav/linux](https://github.com/TravMurav/linux/tree/x13s-6.18-v1.1-cxsd)：包含一些 sc8280xp 平台 EL2 支持补丁的 Linux 内核树。
- [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)：在高通平台上预启动 DSP 固件的 UEFI 应用程序，可在引导链中用于启动 Linux 之前。
