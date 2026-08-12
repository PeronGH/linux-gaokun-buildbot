#!/usr/bin/env bash
# Import this repository's DTS and defconfig into a kernel source tree.
#
# These files are owned outright rather than carried as a diff against
# mainline, so they are copied in and committed instead of being applied as a
# patch. That keeps dts/ and defconfig/ the single source of truth and means a
# kernel bump can never produce a context conflict in them.

import_local_sources() {
  local gaokun_dir="$1"
  local kern_src="$2"

  install -m644 "$gaokun_dir"/dts/*.dts "$gaokun_dir"/dts/*.dtsi \
    "$kern_src/arch/arm64/boot/dts/qcom/"
  install -m644 "$gaokun_dir"/defconfig/gaokun3_defconfig \
    "$kern_src/arch/arm64/configs/"

  git -C "$kern_src" add -A
  git -C "$kern_src" commit -q -m "arm64: gaokun3: import local dts and defconfig"
}
