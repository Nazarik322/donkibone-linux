#!/usr/bin/env bash
# Renders all Celestia theme assets from the caelestia logo and wallpaper:
# rEFInd theme, USB stick GRUB theme, installer branding images, default wallpaper.
set -euo pipefail
source "$(dirname "$0")/common.sh"

# Same release and checksum as pkgbuilds/caelestia-shell/PKGBUILD
SHELL_VERSION=2.5.0
SHELL_SHA256=6bef9feff9f9c6afeb6fdf0b9bb1cfc3cfd7dff4c2a020e8079d6720975f3b6a
SHELL_URL="https://github.com/caelestia-dots/shell/releases/download/v$SHELL_VERSION/caelestia-shell-v$SHELL_VERSION.tar.gz"

src="$WORK_DIR/sources"
mkdir -p "$src"

tarball="$src/caelestia-shell-v$SHELL_VERSION.tar.gz"
if [[ ! -f "$tarball" ]]; then
    msg2 "Downloading caelestia shell $SHELL_VERSION assets"
    curl -fsSL "$SHELL_URL" -o "$tarball.part"
    mv "$tarball.part" "$tarball"
fi
echo "$SHELL_SHA256  $tarball" | sha256sum -c --quiet - || die "checksum mismatch for $tarball"

assets="$src/caelestia-shell-assets"
rm -rf "$assets"
mkdir -p "$assets"
tar -xzf "$tarball" -C "$assets" --strip-components=2 \
    "caelestia-shell-v$SHELL_VERSION/assets/logo.svg" \
    "caelestia-shell-v$SHELL_VERSION/assets/wallpaper.webp"

rsvg-convert -w 1024 -h 1024 "$assets/logo.svg" -o "$assets/logo.png"

font="$(fc-match -f '%{file}' 'JetBrainsMono Nerd Font:style=Regular')"
[[ "$font" == *JetBrains* ]] || die "JetBrainsMono Nerd Font not found (install ttf-jetbrains-mono-nerd)"

msg2 "Rendering images"
grub_theme="$ROOT_DIR/profile/grub/themes/celestia"
python3 -I "$ROOT_DIR/scripts/make_theme.py" \
    --palette "$ROOT_DIR/theme/palette.env" \
    --wallpaper "$assets/wallpaper.webp" \
    --logo-png "$assets/logo.png" \
    --font "$font" \
    --refind "$ROOT_DIR/pkgbuilds/celestia-system/files/generated/refind" \
    --grub "$grub_theme" \
    --calamares "$ROOT_DIR/calamares/branding/celestia/generated" \
    --wallpapers "$ROOT_DIR/pkgbuilds/celestia-system/files/generated/wallpapers"

msg2 "Building GRUB fonts"
# Latin + Cyrillic + punctuation keeps the fonts small.
for size in 20 32; do
    grub-mkfont -s "$size" -n Celestia -r 0x20-0x7E,0xA0-0x4FF,0x2000-0x206F \
        -o "$grub_theme/celestia-$size.pf2" "$font"
done

msg "Theme assets ready"
