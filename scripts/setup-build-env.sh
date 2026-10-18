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

# Containers cannot give pacman's hooks a private network ("could not isolate the
# network"): turn the sandbox off, as CachyOS's own ISO build does.
if ! grep -q '^DisableSandbox' /etc/pacman.conf; then
    sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
fi

# A fresh container has a keyring directory but no signing key; the CachyOS script needs
# one to sign its repository key. --init does nothing when a key already exists.
pacman-key --init
pacman-key --populate archlinux

if ! grep -q '^\[cachyos\]' /etc/pacman.conf; then
    msg "Adding CachyOS repositories (official script, may ask for confirmation)"
    tmp="$(mktemp -d)"
    curl -fsSL https://mirror.cachyos.org/cachyos-repo.tar.xz -o "$tmp/cachyos-repo.tar.xz"
    tar -xf "$tmp/cachyos-repo.tar.xz" -C "$tmp"
    if [[ -n "${CI:-}" ]]; then
        # CI has no terminal: answer the script's confirmation questions with "yes"
        (cd "$tmp/cachyos-repo" && yes | ./cachyos-repo.sh)
    else
        (cd "$tmp/cachyos-repo" && ./cachyos-repo.sh)
    fi
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
