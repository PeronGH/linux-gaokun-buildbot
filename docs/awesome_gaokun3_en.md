# Awesome Gaokun3

A curated list of Gaokun3-related resources. Make Gaokun3 Great Again!

## Waydroid

[Waydroid](https://waydroid.org/): A container-based approach to run Android on Linux, with support for hardware acceleration and integration with the host system. Waydroid can run on Gaokun3 with the latest kernel and firmware, providing a smooth Android experience on the device.

[dragon-waydroid](https://github.com/dragon-waydroid) is a custom Waydroid build based on the upstream [Waydroid-ATV](https://github.com/Waydroid-ATV) includes v4l2m2m decoding support for Qualcomm mainline devices like Gaokun3. Provides LineageOS 23.2 Android 16 QPR2 image.

### Waydroid only Sessions

[Setting up Waydroid only Sessions](https://docs.waydro.id/faq/setting-up-waydroid-only-sessions): A guide on how to configure Waydroid to run in a dedicated session. Before setting it up, you need to install some Waydroid window managers using commands such as `sudo apt install mutter`.

## MPV

Check [Radxa Q6A Docs](https://docs.radxa.com/en/dragon/q6a/system-config/mpv) for instructions on how to set up MPV with hardware acceleration. It also applies to Gaokun3.

## Steam ARM64

Check https://interfacinglinux.com/community/sbcsoftware/native-steam-client-for-arm-linux/ for details.

Pay attention to the libvpx compatibility link on newer distributions.

Or use the following script to install the native Steam client for ARM Linux on Gaokun3:
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

After completing the setup, you also need to download [Proton 11 ARM64](https://archive.org/download/arm-64proton-runtime-64.tar), which already includes [FEX-EMU](https://github.com/FEX-Emu/FEX), a tool for translating ARM64 to x86_64.
