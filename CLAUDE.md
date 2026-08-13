# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Audience split

`README.md` and `docs/*.md` are written for someone who owns a MateBook E Go and wants to flash, boot, dual-boot or repair it. Keep them to what such a person acts on. Build-system rationale, upstream evidence and rejected alternatives belong here instead, and inline comments stay to a line or two of local "why". If a comment or doc paragraph explains a distribution-policy decision, move it into this file rather than growing the source.

## What gets built

Three GitHub Actions workflows, all `workflow_dispatch`, all sharing the numbered scripts in `scripts/ci/`:

| Workflow | Product |
| --- | --- |
| `gaokun3-package-rpms.yml` | `kernel-gaokun3`, `kernel-modules-gaokun3`, `kernel-devel-gaokun3`, `linux-firmware-gaokun3` (plus `*-el2` variants) |
| `fedora-gaokun3-release.yml` | Fedora Workstation disk image; optionally calls the RPM workflow first |
| `gaokun3-rescue-release.yml` | CLI-only USB rescue image |

Script order is the numeric prefix: `10` fetch prebuilt RPMs from a release → `20` build kernel variants → `30` bootstrap the rootfs with dnf → `50`/`55` create the image → `60`/`65` compress and write release notes. `70` builds the RPMs and is what `10` later downloads. Each script takes its inputs as required environment variables checked with `: "${VAR:?}"` at the top; the workflow YAML is the only caller that sets them.

## Working on this from a dev machine

The build needs Linux, `sudo`, loop devices and `dnf --installroot`, so it cannot run on macOS and is not worth running locally at all. Verify by reading and by static analysis, then let CI build:

```sh
shellcheck scripts/ci/*.sh scripts/ci/lib/*.sh scripts/lib/*.sh scripts/local/*.sh
bash -n <script>
```

`.shellcheckrc` sets `external-sources`/`source-path=SCRIPTDIR` so sourced libs resolve. There is no test suite; the real check is a CI run plus a boot on the device, which only the user can do. Privileged commands are handed to the user rather than run here.

RPM specs are `packaging/rpm/*.spec.in` templates with `@PLACEHOLDER@` tokens substituted by `render_spec_template` in `70_build_package_rpms.sh`; `rpmspec`/`rpmlint` cannot parse them directly.

## Architecture notes that span files

**Kernel source assembly** (`20_build_kernel_variants.sh`): `patches/upstream/*` then `patches/others/*` are applied with `git am` to a checkout of `torvalds/linux` at `KERNEL_TAG`, then `scripts/lib/import_local_sources.sh` *copies* `dts/` and `defconfig/` into the tree and commits them. Those two directories are owned outright, not diffed against mainline, so a kernel bump cannot conflict in them — edit the files here, never a patch. The base tree is snapshotted before `patches/el2/*` is applied on top, so the EL2 variant is a second build of the same source with `LOCALVERSION=-gaokun3-el2`.

**Boot layout** is BLS via `kernel-install` (`layout=bls`), with systemd-boot on a 1 GiB ESP; nothing boots out of `/boot`. Invariants that several files depend on together:

- `--entry-token=os-id` everywhere, recorded in `/etc/kernel/entry-token`. The default `machine-id` token would resolve differently on the device than at build time and orphan the entries. The rescue image uses its own token so a stick and a target install never collide.
- `kernel-install` owns the initramfs. Never call `dracut` before it: `50-dracut.install` builds into its own staging area and only reuses a pre-built image named `initrd` next to the kernel, which `dracut --force`'s `/boot/initramfs-<kver>.img` is not.
- `/etc/machine-id` ships as `uninitialized`, matching Fedora's kiwi `config.sh`. systemd treats missing or `uninitialized` as first boot; an *empty* file gets an id but is explicitly not a first boot. Because first boot now really fires, `systemd-firstboot` pre-answers locale/keymap/timezone at build time (as kiwi does for `<locale>/<keytable>/<timezone>`), or `systemd-firstboot.service` — ordered before `sysinit.target` with `StandardInput=tty` — would block the boot in front of gdm.
- `kernel-gaokun3`'s `%posttrans` rewrites `loader.conf`'s `default` so an installed kernel becomes the booting one; the EL2 package must never claim it.
- Fedora's `51-dracut-rescue.install` is symlinked to `/dev/null`: its `0-rescue` entry carries no `devicetree` and cannot boot this device.

**Image assets** shared by both images live in `tools/image-assets/` and are installed by `scripts/ci/lib/common_image.sh`, which also selects the `desktop` or `rescue` module-load profile. Adding a file under `modules-load.d/` requires updating the `rescue` profile's explicit list.

## Fedora alignment

The ownership boundary: Fedora owns distribution policy, boot layout, kernel lifecycle, package composition, security defaults and generic firmware. This repo owns the Gaokun3 DTB, the drivers and fixes that are not upstream yet, model firmware, physical display/input quirks, and the experimental EL2 path. When something here answers a question Fedora already answers, match Fedora.

Reference points worth re-reading before changing boot or image behaviour: Fedora's [`fedora-kiwi-descriptions`](https://pagure.io/fedora-kiwi-descriptions) `config.sh` and `Fedora.kiwi`, the [Snapdragon WoA install page](https://fedoraproject.org/wiki/Snapdragon_WoA_Laptop_Install), and Fedora's kernel dist-git scriptlets.

### Kernel command line

Set in `50_make_image_fedora.sh` and `55_make_image_rescue.sh`. Every entry needs a reason:

| Parameter | Why |
| --- | --- |
| `clk_ignore_unused`, `pd_ignore_unused` | Fedora-documented SC8280XP workarounds. `pd_ignore_unused` may be obsolete since power-domain `sync_state` landed — untested here. |
| `arm64.nopauth`, `efi=noruntime` | Fedora-documented 8cx Gen 3 firmware workarounds |
| `fbcon=rotate:1` | Portrait panel |
| `usbhid.quirks=0x12d1:0x10b8:0x20000000` | Huawei keyboard |
| `plymouth.enable=0` | Plymouth draws through DRM and ignores `fbcon=rotate:1`, so splash and details view come out sideways. UX, not boot safety. |
| `pcie_aspm.policy=powersupersave` | Global policy override with no Fedora precedent and no measurement behind it. Candidate for removal. |
| `modprobe.blacklist=simpledrm` | EL2 only |

Removed as no-ops and not to be reintroduced: `consoleblank=0` (`blankinterval` starts at 0 in `drivers/tty/vt/vt.c`) and `psi=1` (`CONFIG_PSI=y`, `PSI_DEFAULT_DISABLED` unset). `systemd.tpm2_wait=0` is documented by Fedora for 8cx Gen 3 but has never been shown necessary here.

### Known divergences not yet addressed

An external audit (2026-08-13, against `f224d2f`) catalogued these. Batch 1 — machine-id first-boot semantics, the duplicate `dracut` run, the dead cmdline entries, and a `modules-load.d/battery.conf` naming built-in drivers — is fixed. What remains, roughly by value:

- `defconfig/gaokun3_defconfig` is an independent distribution kernel policy, not a delta over Fedora's aarch64 config: of 484 shared symbols, 118 differ, including LSM order, preemption, tracing and whole driver families. The target is Fedora's config plus a small reviewed Gaokun fragment.
- `linux-firmware-gaokun3` `Conflicts`/`Obsoletes` `atheros-firmware` and `qcom-firmware`, and `30_bootstrap_rootfs.sh` erases them with `rpm -e --nodeps` before installing with `--allowerasing`. Should be additive, overriding through `/usr/lib/firmware/updates/`.
- The kernel RPMs do not implement Fedora's kernel package semantics (`installonlypkg(kernel)`, `kernel-uname-r` provides, module-tree layout), and compensate with `/etc/dnf/protected.d` and a global `excludepkgs`. The Fedora-kernel exclusion itself is justified — stock kernels cannot boot this device.
- `kernel-gaokun3`'s `%posttrans` runs `kernel-install add` during rootfs bootstrap too, inside a container with no ESP. It appears to fail there and leave nothing behind — if it ever succeeded it would write entries under `/boot` that later win over the ESP — but nothing checks.
- The `add_drivers` list is duplicated between both image scripts and the packaged dracut fragment in `70_build_package_rpms.sh`, and has already drifted. With `hostonly=no`, most of it is redundant; only what is needed before switch-root belongs there.
- The remaining `modules-load.d` files force modules that should autoload from DT/PCI/HID aliases. Each removal needs a cold-boot log, not reasoning.
- The package selection is a curated remix (pruned Workstation plus RPM Fusion and `libavcodec-freeworld`), which the README's stated goals acknowledge but which is not stock Workstation.
- The standard image uses systemd-boot where Fedora aarch64 uses GRUB+BLS; that choice is what creates the ESP-copy, entry-token, rescue-entry and default-selection machinery.

Anything requiring hardware evidence (module autoload, ASPM, `pd_ignore_unused`) can only be settled by the user on the device — ask for a cold-boot log rather than guessing.

## Conventions

Commit subjects are plain sentences in the imperative with no `type:` prefix, e.g. "Mount the ESP the way Fedora does, and stop building initramfses twice". The body carries the evidence: what upstream says, what was measured, what was rejected. `main` is the working branch; the user pushes.
