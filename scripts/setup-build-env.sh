#!/usr/bin/env bash
# One-time preparation of the build machine (Arch Linux in WSL2).
#   - adds the CachyOS repositories (official cachyos-repo script)
#   - installs archiso, devtools and the tools used by the theme generator
#   - creates the local package repo
# Usage: sudo ./scripts/setup-build-env.sh
set -euo pipefail
source "$(dirname "$0")/common.sh"

[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] || die "run with sudo from your normal user, not as root"
command -v pacman >/dev/null || die "this must run on Arch Linux"

msg "Updating the system"
pacman -Syu --noconfirm --needed base-devel git curl

if ! grep -q '^\[cachyos\]' /etc/pacman.conf; then
    msg "Adding CachyOS repositories (official script, may ask for confirmation)"
    tmp="$(mktemp -d)"
    curl -fsSL https://mirror.cachyos.org/cachyos-repo.tar.xz -o "$tmp/cachyos-repo.tar.xz"
    tar -xf "$tmp/cachyos-repo.tar.xz" -C "$tmp"
    (cd "$tmp/cachyos-repo" && ./cachyos-repo.sh)
    rm -rf "$tmp"
else
    msg2 "CachyOS repositories already configured"
fi

msg "Installing build tools"
pacman -S --noconfirm --needed \
    archiso mkinitcpio-archiso devtools grub libisoburn mtools dosfstools squashfs-tools \
    cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist \
    python python-pillow librsvg jq rsync ttf-jetbrains-mono-nerd

msg "Creating the local package repo at $LOCAL_REPO_DIR"
install -d -o "$SUDO_USER" -g "$SUDO_USER" "$LOCAL_REPO_DIR"
sudo -u "$SUDO_USER" bash -c "source '$ROOT_DIR/scripts/common.sh'; ensure_local_repo"

# systemd-nspawn (used by devtools to build in a clean chroot) needs systemd in WSL.
if grep -qi microsoft /proc/version 2>/dev/null && [[ "$(ps -p 1 -o comm=)" != systemd ]]; then
    warn "systemd is not running in WSL. Add this to /etc/wsl.conf, then run 'wsl --shutdown' in Windows:"
    warn "  [boot]"
    warn "  systemd=true"
fi

msg "Done. Next: ./build.sh (as $SUDO_USER, not root)"
