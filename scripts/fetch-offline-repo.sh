#!/usr/bin/env bash
# Downloads the driver packages chwd may install (packages/drivers.txt) plus their
# dependencies that are not already part of the image, into an offline repo that
# goes onto the USB stick. The installer runs chwd against this repo.
set -euo pipefail
source "$(dirname "$0")/common.sh"

[[ -f "$RESOLVED_LIST" ]] || die "run scripts/build-packages.sh first"

fake_root="$WORK_DIR/offline-root"
host_cache=/var/cache/pacman/pkg
pm=(sudo pacman --config "$BUILD_PACMAN_CONF" --root "$fake_root" --dbpath "$fake_root/var/lib/pacman"
    --hookdir "$fake_root/no-hooks" --noconfirm --noprogressbar)

msg "Preparing the offline driver repo"
sudo rm -rf "$fake_root" "$OFFLINE_REPO_DIR"
mkdir -p "$fake_root/var/lib/pacman" "$OFFLINE_REPO_DIR"

# Register the image's packages in a throwaway database (no files are extracted),
# so the download step below only fetches what the image does not already have.
"${pm[@]}" -Sy >/dev/null
mapfile -t image_pkgs < <(sort -u "$RESOLVED_LIST")
"${pm[@]}" --cachedir "$host_cache" -S --needed --dbonly --noscriptlet "${image_pkgs[@]}" >/dev/null

# drivers.txt: "pkg?" marks packages that may not exist in the repos (skipped).
sync_private_db
drivers=()
while read -r spec; do
    name="${spec%\?}"
    if in_repos "$name"; then
        drivers+=("$name")
    elif [[ "$spec" == *'?' ]]; then
        warn "optional driver package '$name' not in the repos, skipping"
    else
        die "driver package '$name' not found in the repos (packages/drivers.txt)"
    fi
done < <(read_list "$ROOT_DIR/packages/drivers.txt")
"${pm[@]}" --cachedir "$OFFLINE_REPO_DIR" -Sw "${drivers[@]}"
sudo chown -R "$(id -u):$(id -g)" "$OFFLINE_REPO_DIR"

repo-add -q "$OFFLINE_REPO_DIR/$OFFLINE_REPO_NAME.db.tar.gz" "$OFFLINE_REPO_DIR"/*.pkg.tar.zst

# Consistency check: every package a chwd graphics profile lists, including the ones
# its conditional_packages scripts may echo, should be available offline (or already
# in the image). Legacy closed NVIDIA drivers are not covered.
chwd_pkg="$(find "$host_cache" -maxdepth 1 -name 'chwd-[0-9]*.pkg.tar.zst' | sort -V | tail -n1)"
if [[ -n "$chwd_pkg" ]]; then
    profiles="$(bsdtar -xOf "$chwd_pkg" --include='*graphic_drivers/profiles.toml' 2>/dev/null || true)"
    available=" $(printf '%s ' "${image_pkgs[@]}" "${drivers[@]}") "
    missing=()
    while read -r p; do
        [[ "$available" == *" $p "* ]] || missing+=("$p")
    done < <( { awk '/^\[/{legacy = ($0 ~ /(580|470)xx/)} !legacy && /^packages = /' <<< "$profiles" \
                    | sed -E "s/^packages = ['\"]?//; s/['\"]$//"
                awk '/^\[/{legacy = ($0 ~ /(580|470)xx/)}
                     /conditional_packages = """/{cond = 1; next}
                     cond && /"""/{cond = 0}
                     cond && !legacy && /echo "/' <<< "$profiles" \
                    | sed -E 's/.*echo "([^"]*)".*/\1/'
              } | tr ' ' '\n' | grep -v '^\$' | sed '/^$/d' | sort -u)
    if (( ${#missing[@]} )); then
        warn "chwd profiles reference packages missing from packages/drivers.txt: ${missing[*]}"
    fi
else
    warn "chwd package not found in $host_cache, skipped the profile consistency check"
fi

msg "Offline repo ready: $(du -sh "$OFFLINE_REPO_DIR" | cut -f1) in $OFFLINE_REPO_DIR"
