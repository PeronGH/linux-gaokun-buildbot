# Awesome Gaokun3
Gaokun3 相关资源整理。让 Gaokun3 再次伟大！

## Waydroid

[Waydroid](https://waydroid.org/)：一种基于容器的方案，可在 Linux 上运行 Android，支持硬件加速以及与宿主系统的深度集成。
在搭配最新内核与固件的情况下，Waydroid 可以在 Gaokun3 上运行，并提供流畅的 Android 使用体验。

[dragon-waydroid](https://github.com/dragon-waydroid) 是基于上游 [Waydroid-ATV](https://github.com/Waydroid-ATV) 的自定义 Waydroid 构建版本，加入了针对 Qualcomm 主线设备（例如 Gaokun3）的 v4l2m2m 视频解码支持。提供基于 LineageOS 23.2 Android 16 QPR2 的系统镜像。

### Waydroid 独占会话

[Setting up Waydroid only Sessions](https://docs.waydro.id/faq/setting-up-waydroid-only-sessions)：介绍如何将 Waydroid 配置为独立会话运行。在开始配置之前，需要先安装一些 Waydroid 所需的窗口管理器，例如 `sudo apt install mutter`

## MPV

参考 [Radxa Q6A 文档](https://docs.radxa.com/en/dragon/q6a/system-config/mpv) 来配置支持硬件加速的 MPV。同样适用于 Gaokun3。

## Steam ARM64

参考 https://interfacinglinux.com/community/sbcsoftware/native-steam-client-for-arm-linux/

注意在较新的发行版中，需要处理 `libvpx` 兼容性问题。

或者你也可以直接使用下面的脚本，在 Gaokun3 上安装 ARM Linux 原生 Steam 客户端：
```bash
#!/usr/bin/env bash
set -e

STEAM_ROOT="$HOME/.local/share/Steam"
STEAM_RT="$STEAM_ROOT/steamrtarm64"
BOOTSTRAP_URL="https://client-update.steamstatic.com/bins_linuxarm64_linuxarm64.zip.0f11199e9a58a0ec4aab3833152ada1b2e56c846"

echo "==> Install dependencies"
sudo dnf install -y ca-certificates curl unzip xdg-utils nss gtk2 libvpx SDL3 libavif

echo "==> Prepare Steam directory"
mkdir -p "$STEAM_ROOT/package" "$HOME/.steam" "$HOME/.local/share/applications"

if [ ! -x "$STEAM_RT/steam" ]; then
  echo "==> Download Steam ARM64 bootstrap"
  TMPDIR="$(mktemp -d)"
  curl -fL "$BOOTSTRAP_URL" -o "$TMPDIR/steam-arm64.zip"
  unzip -q "$TMPDIR/steam-arm64.zip" 'steamrtarm64/*' -d "$STEAM_ROOT"
  rm -rf "$TMPDIR"
fi

echo "==> Enable public beta and links"
printf 'publicbeta\n' > "$STEAM_ROOT/package/beta"
ln -sfn "$STEAM_ROOT" "$HOME/.steam/steam"
chmod -R u+rwX "$STEAM_RT"

echo "==> Add libvpx compatibility link"
# The Steam bootstrap looks for libvpx.so.6; point it at whatever soname this
# Fedora actually ships rather than assuming a version.
if [ ! -e /usr/lib64/libvpx.so.6 ]; then
  VPX_LIB="$(ldconfig -p | awk '/libvpx\.so\.[0-9]+$/ {print $NF; exit}')"
  if [ -z "$VPX_LIB" ]; then
    echo "libvpx not found; install it before running Steam" >&2
    exit 1
  fi
  sudo ln -s "$VPX_LIB" /usr/lib64/libvpx.so.6
fi

echo "==> Create application menu launcher"
cat > "$HOME/.local/share/applications/steam-arm64.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Steam
Comment=Native Steam client for ARM Linux
Exec=$STEAM_RT/steam %U
Path=$STEAM_RT
Icon=$STEAM_ROOT/public/steam_tray.ico
Terminal=false
Categories=Game;
StartupNotify=true
EOF

chmod +x "$HOME/.local/share/applications/steam-arm64.desktop"
update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

echo
echo "Done. Start Steam from application menu."
```

完成安装后，你还需要下载 [Proton 11 ARM64](https://archive.org/download/arm-64proton-runtime-64.tar)，该版本已经内置了 [FEX-EMU](https://github.com/FEX-Emu/FEX)，用于将 ARM64 指令动态翻译为 x86_64。
