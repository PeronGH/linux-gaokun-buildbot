# linux-gaokun-buildbot

Build scripts, patches, kernel config, DTS files, tools, and firmware for Linux images targeting the Huawei MateBook E Go 2023 (codename `gaokun3`) based on Qualcomm Snapdragon 8cx Gen3 (`SC8280XP`).

The image pipeline now uses `systemd-boot` by default and can optionally build a second EL2 kernel variant with `CONFIG_LOCALVERSION="-gaokun3-el2"`.

## Goals

These are ordered. When they conflict, the earlier one wins.

1. **The best experience on the MateBook E Go.** Hardware enablement comes before everything else. The DTS, the kernel config, the firmware bundle, and cmdline entries such as `fbcon=rotate:1` and `usbhid.quirks` exist because this device needs them, and they stay even where they are unlike stock Fedora. RPM Fusion and `libavcodec-freeworld` ship enabled for the same reason: media playback should work out of the box.
2. **A stock Fedora experience.** The reference is Fedora's own aarch64 Workstation raw disk image, `Fedora-Workstation-Disk-*.aarch64.raw.xz` under [`releases/<release>/Workstation/aarch64/images/`](https://download.fedoraproject.org/pub/fedora/linux/releases/), for whichever release is being built. [Fedora's Workstation documentation](https://docs.fedoraproject.org/en-US/workstation-docs/) counts as reference too: anything Fedora documents for aarch64 Workstation applies here. Where the hardware does not force our hand, match it rather than invent: Fedora's Btrfs layout (`root` and `home` subvolumes, `compress=zstd:1`), SELinux enforcing, no passwordless `sudo`. It also decides what we leave out — if that image does not ship a Pinyin input method or a language's translations, neither do we. Deviations should be deliberate, and worth writing down.
3. **Safe to daily drive.** It should not be easier to break than an x86 Fedora install: `kernel-gaokun3` is protected from removal, Fedora's own kernels are excluded because they cannot boot this device, and installing a kernel makes it the one that boots. This ranks last on purpose, so guard rails Fedora itself does not have are not added. `dnf system-upgrade` is left alone even though it is a real risk here.

## What is included

### Repository layout

- `patches/`: kernel patches and device support changes
- `defconfig/`: local kernel configuration used by CI/manual builds
- `drivers/`: local mirrors of the patched driver sources kept in the patch series
- `dts/`: local mirrors of the patched device tree sources kept in the patch series
- `docs/`: bilingual usage/build guides and platform notes
- `firmware/`: minimal firmware bundle used by the image build
- `packaging/`: distro kernel and firmware package templates and metadata
- `tools/`: device-specific helper scripts, service files, and EL2 EFI payloads
- `scripts/ci/`: workflow build, image creation, and packaging scripts
- `scripts/local/`: some useful scripts that can be run on the local device

### Package outputs

The package pipeline builds and installs dedicated package sets:

- **Fedora (RPM)**: `kernel-gaokun3`, `kernel-modules-gaokun3`, `kernel-devel-gaokun3`, `linux-firmware-gaokun3`
- **Optional EL2 variants**: `*-gaokun3-el2` package set for the second EL2 kernel build
- Fedora kernel RPMs now ship a matching `dracut.conf.d` snippet and run `dracut` + `kernel-install add` in `%posttrans`, so installing or upgrading the package refreshes the initramfs and BLS entry automatically.

### Releases

- Fedora image releases contain compressed installable images.
- Gaokun rescue USB releases contain a CLI-only Fedora image that boots this device from a USB stick, for installing the image above onto the internal disk or repairing an installation that no longer boots. It ships no installer: the procedure is [rescue_usb_guide_en.md](docs/rescue_usb_guide_en.md). **It has a published password (`fedora` / `fedora`) and `sshd` enabled**, so anyone on the same network can log in while it is running.
- Gaokun RPM releases contain the standalone kernel and firmware package sets used by the image workflow.

### Patch Sources

- `upstream/*` and `others/0017`: adapted from [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun) for the base SC8280XP / gaokun3 enablement, display bring-up, EC suspend/resume, ADSP FastRPC, and DSI stability work
- `others/0001`: adapted from [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux) to avoid setting `USE_BDADDR_PROPERTY` when the adapter address is invalid
- `others/0002`: local change in this repository to enable DSC and allow 60 Hz / 120 Hz switching
- `others/0003`: adapted from [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux) to add the Himax HX83121A SPI touchscreen driver
- `others/0004`: adapted from [TheUnknownThing/linux-gaokun](https://github.com/TheUnknownThing/linux-gaokun) to improve UCSI handling and module wiring for the Type-C path
- `dts/` and `defconfig/`: copied into the kernel tree by `scripts/lib/import_local_sources.sh` rather than carried as a patch, so they cannot conflict on a kernel bump
- **[Optional]** `el2/*`: adapted from [TravMurav/linux](https://github.com/TravMurav/linux/tree/x13s-6.18-v1.1-cxsd) for the EL2 boot path, including SMP2P handover, remoteproc attach/restart flow, SCM/SHM owner handling, and related rpmsg/QRTR/pmic_glink stability fixes

### Tool Sources

- `tools/audio`, `tools/bluetooth`: adapted from [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux)
- `tools/el2/qebspilaa64.efi`: sourced from [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil)
- `tools/el2/slbounceaa64.efi`: sourced from [TravMurav/slbounce](https://github.com/TravMurav/slbounce)
- `tools/touchscreen-tuner`: adapted from [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux), with GTK4 GUI improvements in this repository

## Boot artifact layout

The image and local-install workflows now follow the standard `kernel-install` + BLS flow instead of hand-writing `systemd-boot` entries.

- BLS entry names and entry directories are generated by `kernel-install` with `--entry-token=os-id`, giving `loader/entries/fedora-<kernel-release>.conf`. The default `machine-id` token is deliberately avoided: the image ships `/etc/machine-id` as `uninitialized`, as Fedora's own images do, so each device generates its own on first boot, and entries named after a build-time id would be orphaned.
- Kernel, initrd/initramfs, and DTB files copied into the ESP are also placed under the matching `<entry-token>/<kernel-release>/` directory automatically by the distro hook.
- A compatibility copy of the DTB is also kept in `/boot` so users can switch to GRUB more easily later.
- Fedora DTBs are installed in `/usr/lib/modules/<kernel-release>/dtb/qcom/` for `kernel-install`, plus `/boot/dtb-<kernel-release>/qcom/` as a compatibility copy.
- The Gaokun3 image scripts provide `/etc/kernel/cmdline` and `/etc/kernel/devicetree`, then call `kernel-install add` to populate the final BLS entry.
- The boot is verbose and Plymouth is off (`plymouth.enable=0`), where stock Fedora has `rhgb quiet`. Plymouth draws through DRM and ignores `fbcon=rotate:1`, so both its splash and its details view would come out sideways on this portrait panel; the kernel console honours the rotation. `systemd-boot`'s entry editor is enabled (`editor yes`) so the cmdline, `selinux=0` included, can be changed from the device instead of by mounting the ESP elsewhere.

## Getting started

- Release: <https://github.com/KawaiiHachimi/linux-gaokun-build/releases>
- [Rescue USB guide](docs/rescue_usb_guide_en.md)
- [Dual-boot guide](docs/dual_boot_guide_en.md)
- [EL2 implementation notes](docs/el2_kvm_guide_en.md)
- [Awesome Gaokun3](docs/awesome_gaokun3_en.md)
- [Build guide – Fedora 44](docs/matebook_ego_build_guide_fedora44_en.md)

### Language and input

The image ships `LANG=en_US.UTF-8` and no input method, matching the reference
Workstation image. Add your language in GNOME Settings and Fedora offers the
matching translations and input method.

For Chinese specifically there are two reasonable paths, and an image cannot
pick between them for you:

- `fcitx5-chinese-addons` works immediately, and its Pinyin dictionary is
  usually paired with `fcitx5-pinyin-zhwiki`.
- `fcitx5-rime` with [rime-ice](https://github.com/iDvel/rime-ice) (雾凇拼音) is
  what most people who care end up on. It needs its own configuration, which is
  the point of it.

## Feature Support

For an overview of hardware support status on the device, see [right-0903/linux-gaokun `## Feature Support`](https://github.com/right-0903/linux-gaokun?tab=readme-ov-file#feature-support).

## References

- [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun) : The main source of the kernel patches and device support work, with detailed commit messages and explanations.
- [TheUnknownThing/linux-gaokun](https://github.com/TheUnknownThing/linux-gaokun) : Another fork of the kernel patches and device support work, with some unique commits and explanations for Touchscreen and EC.
- [whitelewi1-ctrl/matebook-e-go-linux](https://github.com/whitelewi1-ctrl/matebook-e-go-linux) : The earliest repo to fix panel backlight problem, with some additional resources and modifications for Gaokun3 Linux support.
- [gaokun on AUR](https://aur.archlinux.org/packages?O=0&K=gaokun) : Several AUR packages built for Gaokun3, including kernel and firmware packages.
- [chenxuecong2/firmware-huawei-gaokun3](https://github.com/chenxuecong2/firmware-huawei-gaokun3) : A firmware bundle repository for Gaokun3.
- [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux) : The upstream source for the directly integrated Himax HX83121A Linux touchscreen driver and tuning algorithm in this repository.
- [awarson2233/EGoTouchRev](https://github.com/awarson2233/EGoTouchRev) : The original Windows-side touchscreen algorithm project referenced by EGoTouchRev-Linux, and an important upstream reference for the Gaokun3 touchscreen tuning pipeline.
- [TravMurav/slbounce](https://github.com/TravMurav/slbounce) : A UEFI application that enables EL2 support and Secure Launch on Gaokun3.
- [TravMurav/linux](https://github.com/TravMurav/linux/tree/x13s-6.18-v1.1-cxsd) : A Linux kernel tree with some useful patches for EL2 support on sc8280xp platforms.
- [stephan-gh/qebspil](https://github.com/stephan-gh/qebspil) : A UEFI application that pre-launches the DSP firmware on Qualcomm platforms, which can be used in the boot chain before launching Linux.
