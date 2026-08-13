#!/usr/bin/env bash
set -euo pipefail

# Module autoloading and dependency ordering for the device. The "rescue"
# profile drops audio and bluetooth, which a CLI rescue environment has no use
# for, and keeps the panel and Wi-Fi modules. The EC, battery and UCSI drivers
# need no entry of their own: they are built into the kernel.
install_module_config() {
  local rootfs_dir="$1"
  local gaokun_dir="$2"
  local profile="$3"
  local conf

  case "$profile" in
    desktop)
      sudo mkdir -p "$rootfs_dir/etc/modules-load.d" "$rootfs_dir/etc/modprobe.d"
      sudo cp -a "$gaokun_dir/tools/image-assets/etc/modules-load.d/." \
        "$rootfs_dir/etc/modules-load.d/"
      sudo cp -a "$gaokun_dir/tools/image-assets/etc/modprobe.d/." \
        "$rootfs_dir/etc/modprobe.d/"
      ;;
    rescue)
      for conf in display wifi; do
        sudo install -Dm644 \
          "$gaokun_dir/tools/image-assets/etc/modules-load.d/$conf.conf" \
          "$rootfs_dir/etc/modules-load.d/$conf.conf"
      done
      ;;
    *)
      echo "unknown module config profile: $profile" >&2
      return 1
      ;;
  esac
}

install_common_image_assets() {
  local rootfs_dir="$1"
  local gaokun_dir="$2"
  local executable_assets=(
    "tools/bluetooth/patch-nvm-bdaddr.py:/usr/local/bin/patch-nvm-bdaddr.py"
    "tools/touchscreen-tuner/touchscreen-tune:/usr/local/bin/touchscreen-tune"
  )
  local service_assets=(
    "tools/bluetooth/patch-nvm-bdaddr.service:/etc/systemd/system/patch-nvm-bdaddr.service"
  )
  local data_assets=(
    "tools/audio/sc8280xp.conf:/usr/share/alsa/ucm2/Qualcomm/sc8280xp/sc8280xp.conf"
    "tools/touchscreen-tuner/tune.py:/usr/local/lib/gaokun-touchscreen-tuner/tune.py"
    "tools/touchscreen-tuner/tune-icon.svg:/usr/local/lib/gaokun-touchscreen-tuner/tune-icon.svg"
    "tools/touchscreen-tuner/touchscreen-tune.desktop:/usr/share/applications/touchscreen-tune.desktop"
    # The panel is portrait and has to be rotated before anyone has logged in.
    # mutter reads this system-level file in every session, so it covers the
    # first-boot setup screen and the login screen, which run as their own users,
    # as well as accounts created later. A user changing rotation in Settings
    # writes ~/.config/monitors.xml, which takes precedence.
    "tools/image-assets/etc/xdg/monitors.xml:/etc/xdg/monitors.xml"
  )
  local asset src dest

  sudo mkdir -p \
    "$rootfs_dir/etc/udev/rules.d" \
    "$rootfs_dir/etc/systemd/system" \
    "$rootfs_dir/etc/xdg" \
    "$rootfs_dir/etc/gaokun" \
    "$rootfs_dir/usr/local/bin" \
    "$rootfs_dir/usr/local/lib/gaokun-touchscreen-tuner" \
    "$rootfs_dir/usr/share/alsa/ucm2/Qualcomm/sc8280xp" \
    "$rootfs_dir/usr/share/applications"

  install_module_config "$rootfs_dir" "$gaokun_dir" desktop

  for asset in "${executable_assets[@]}"; do
    src="${asset%%:*}"
    dest="${asset#*:}"
    sudo install -Dm755 "$gaokun_dir/$src" "$rootfs_dir$dest"
  done

  for asset in "${service_assets[@]}"; do
    src="${asset%%:*}"
    dest="${asset#*:}"
    sudo install -Dm644 "$gaokun_dir/$src" "$rootfs_dir$dest"
  done

  for asset in "${data_assets[@]}"; do
    src="${asset%%:*}"
    dest="${asset#*:}"
    sudo install -Dm644 "$gaokun_dir/$src" "$rootfs_dir$dest"
  done
}

install_el2_efi_payloads() {
  local rootfs_dir="$1"
  local gaokun_dir="$2"

  sudo install -d \
    "$rootfs_dir/boot/efi/EFI/systemd/drivers" \
    "$rootfs_dir/boot/efi/firmware"

  sudo install -Dm644 "$gaokun_dir/tools/el2/slbounceaa64.efi" \
    "$rootfs_dir/boot/efi/EFI/systemd/drivers/slbounceaa64.efi"
  sudo install -Dm644 "$gaokun_dir/tools/el2/qebspilaa64.efi" \
    "$rootfs_dir/boot/efi/EFI/systemd/drivers/qebspilaa64.efi"
  sudo install -Dm644 "$gaokun_dir/tools/el2/tcblaunch.exe" \
    "$rootfs_dir/boot/efi/tcblaunch.exe"
  sudo install -Dm644 "$rootfs_dir/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn" \
    "$rootfs_dir/boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn"
  sudo install -Dm644 "$rootfs_dir/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn" \
    "$rootfs_dir/boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn"
  sudo install -Dm644 "$rootfs_dir/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn" \
    "$rootfs_dir/boot/efi/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn"
}
