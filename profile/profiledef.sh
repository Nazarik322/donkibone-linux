#!/usr/bin/env bash
# shellcheck disable=SC2034
# archiso profile for the Celestia installer ISO (based on CachyOS-Live-ISO/archiso).

iso_name="celestia"
iso_label="CELESTIA_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="Celestia (CachyOS + caelestia)"
iso_application="Celestia installer"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
# UEFI only: the target PC boots in UEFI mode and rEFInd is UEFI-only.
bootmodes=('uefi.grub')
arch="x86_64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
# zstd unpacks much faster than xz, which shortens the installation.
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '19' '-b' '1M')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/etc/gshadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/etc/polkit-1/rules.d"]="0:0:750"
  ["/etc/sudoers.d"]="0:0:750"
  ["/etc/sudoers.d/g_wheel"]="0:0:440"
  ["/usr/local/bin/celestia-installer"]="0:0:755"
  ["/usr/local/bin/celestia-diskpick"]="0:0:755"
  ["/usr/local/bin/celestia-disks"]="0:0:755"
  ["/usr/share/celestia-installer/calamares/scripts/"]="0:0:755"
)
