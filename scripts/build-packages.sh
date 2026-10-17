#!/usr/bin/env bash
# Builds every package from packages/system.txt and packages/live.txt that the
# CachyOS/Arch repos do not have, into the local repo:
#   - pkgbuilds/<name>  pinned PKGBUILDs (always preferred, even over the repos)
#   - the AUR           everything else, dependencies resolved recursively
# Builds run in a clean chroot (devtools), or directly with makepkg inside a
# throw-away container when BUILD_MODE=container (GitHub Actions). Writes the final
# package list to $WORK_DIR/packages.resolved for build.sh.
#
# A package is only rebuilt when its "build key" changed (sources, pinned AUR commit,
# Qt version for Qt-dependent packages), so with the previously published repository
# restored (scripts/repo-release.sh restore) unchanged packages keep their files.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[[ $EUID -ne 0 ]] || die "run as your normal user (sudo is used where needed)"

CHROOT_DIR="$WORK_DIR/chroot"
AUR_DIR="$WORK_DIR/aur"
# AUR commits: packages/aur.lock pins them (optional); every build records the
# commits of the packages in the local repo in $WORK_DIR/aur.lock (copy it to
# packages/ to pin them; build.sh also puts a copy next to the ISO).
AUR_LOCK_IN="$ROOT_DIR/packages/aur.lock"
AUR_LOCK_OUT="$WORK_DIR/aur.lock"
LOCAL_BUILD_DIR="$WORK_DIR/pkgbuilds"
STAMP_DIR="$WORK_DIR/stamps"
BUILD_MODE="${BUILD_MODE:-chroot}"   # chroot | container

declare -A LOCAL_PKG      # package name / provides -> pinned PKGBUILD dir
declare -A SATISFIED           # dependency name -> 1 once satisfied
declare -A BUILT          # PKGBUILD dir -> 1 once built
declare -A VISITING       # PKGBUILD dir -> 1 while resolving (cycle detection)
AUR_BUILT=()

# AUR clones ship a .SRCINFO: read it instead of running untrusted PKGBUILD code
# on the host. Pinned PKGBUILDs are ours, makepkg generates theirs.
srcinfo() {
    if [[ "$1" == "$AUR_DIR"/* && -f "$1/.SRCINFO" ]]; then
        cat "$1/.SRCINFO"
    else
        (cd "$1" && makepkg --printsrcinfo)
    fi
}

in_local_repo() {
    pacman --config "$BUILD_PACMAN_CONF" --dbpath "$PRIVATE_DB" -Sl "$LOCAL_REPO_NAME" 2>/dev/null \
        | awk '{print $2}' | grep -qxF "$1"
}

srcinfo_field() {  # <srcinfo> <field regex>
    grep -E "^[[:space:]]*($2) = " <<< "$1" | sed 's/^[^=]*= //'
}

strip_version() { sed -E 's/[<>=].*//' <<< "$1"; }

# Copies of pinned PKGBUILDs, so makepkg never writes into the source tree.
index_local_pkgbuilds() {
    rm -rf "$LOCAL_BUILD_DIR"
    mkdir -p "$LOCAL_BUILD_DIR"
    local dir info name
    for dir in "$ROOT_DIR"/pkgbuilds/*/; do
        dir="${dir%/}"
        cp -r "$dir" "$LOCAL_BUILD_DIR/"
        info="$(srcinfo "$LOCAL_BUILD_DIR/${dir##*/}")"
        while read -r name; do
            [[ -n "$name" ]] && LOCAL_PKG[$(strip_version "$name")]="$LOCAL_BUILD_DIR/${dir##*/}"
        done < <(srcinfo_field "$info" 'pkgname|provides')
    done
}

# Clones the AUR package that provides $1, prints its directory.
aur_fetch() {
    local name="$1" base json
    json="$(curl -fsS "https://aur.archlinux.org/rpc/v5/info?arg%5B%5D=$name")" || return 1
    base="$(jq -r '.results[0].PackageBase // empty' <<< "$json")"
    if [[ -z "$base" ]]; then
        json="$(curl -fsS "https://aur.archlinux.org/rpc/v5/search/$name?by=provides")" || return 1
        base="$(jq -r --arg n "$name" \
            '([.results[] | select(.Name == $n)][0] // .results[0] // {}).PackageBase // empty' <<< "$json")"
    fi
    [[ -n "$base" ]] || return 1

    if [[ -d "$AUR_DIR/$base/.git" ]]; then
        git -C "$AUR_DIR/$base" fetch -q origin >&2 || return 1
    else
        git clone -q "https://aur.archlinux.org/$base.git" "$AUR_DIR/$base" >&2 || return 1
    fi
    local pin=""
    [[ -f "$AUR_LOCK_IN" ]] && pin="$(awk -v b="$base" '$1 == b {print $2}' "$AUR_LOCK_IN")"
    if [[ -n "$pin" ]]; then
        msg2 "AUR $base pinned to ${pin:0:12} (packages/aur.lock)" >&2
    fi
    git -C "$AUR_DIR/$base" checkout -q --detach "${pin:-origin/HEAD}" >&2 || return 1
    sed -i "/^$base /d" "$AUR_LOCK_OUT"
    echo "$base $(git -C "$AUR_DIR/$base" rev-parse HEAD)" >> "$AUR_LOCK_OUT"
    echo "$AUR_DIR/$base"
}

ensure_chroot() {
    if [[ ! -d "$CHROOT_DIR/root" ]]; then
        msg2 "Creating the clean build chroot"
        sudo mkdir -p "$CHROOT_DIR"
        sudo mkarchroot -C "$BUILD_PACMAN_CONF" "$CHROOT_DIR/root" \
            base-devel cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist \
            || die "cannot create the build chroot"
    fi
}

# Hash of a pinned PKGBUILD dir. Generated theme files are excluded: they only change
# together with their inputs, which are covered by the commit count (see build_key).
dir_hash() { (cd "$1" && find . -type f ! -path './src/*' ! -path './pkg/*' ! -path './files/generated/*' \
    ! -name '*.pkg.tar.*' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1); }

# What decides whether a package must be rebuilt.
build_key() {  # <dir> <srcinfo>
    local dir="$1" info="$2" key
    if [[ "$dir" == "$AUR_DIR"/* ]]; then
        key="aur:$(git -C "$dir" rev-parse HEAD)"
    else
        key="local:$(dir_hash "$ROOT_DIR/pkgbuilds/${dir##*/}")"
    fi
    # Packages built against Qt are rebuilt when Qt moves.
    if grep -q 'qt6-' <<< "$info" || grep -q 'celestia:qt-pinned' "$dir/PKGBUILD"; then
        key+=" qt:$(qt_salt)"
    fi
    # celestia-system's version is the commit count, so a new commit is a new package.
    [[ "${dir##*/}" == celestia-system ]] && key+=" v:$(celestia_pkgver)"
    sha256sum <<< "$key" | cut -d' ' -f1
}

# Version stamping of our own packages, applied to the build copy only.
prepare_local_version() {  # <dir>
    local dir="$1"
    [[ "$dir" == "$LOCAL_BUILD_DIR"/* ]] || return 0
    if [[ "${dir##*/}" == celestia-system ]]; then
        sed -i "s/^pkgver=.*/pkgver=$(celestia_pkgver)/" "$dir/PKGBUILD"
    fi
    if grep -q 'celestia:qt-pinned' "$dir/PKGBUILD"; then
        # A rebuild for a new Qt must sort after the previous build of the same version.
        sed -i "s/^pkgrel=.*/pkgrel=1.$(date -u +%Y%m%d%H%M)/" "$dir/PKGBUILD"
    fi
}

# Container mode: builds use the container's own pacman, which must see the local repo.
container_init() {
    [[ "$BUILD_MODE" == container ]] || return 0
    sudo install -m644 "$BUILD_PACMAN_CONF" /etc/pacman.conf
    sudo pacman -Sy --noconfirm
}

build_dir() {
    local dir="$1" info dep stamp pkgs=()
    [[ -n "${BUILT[$dir]:-}" ]] && return 0
    [[ -z "${VISITING[$dir]:-}" ]] || die "dependency cycle involving ${dir##*/}"
    VISITING[$dir]=1

    info="$(srcinfo "$dir")"
    local own=" $(srcinfo_field "$info" 'pkgname' | tr '\n' ' ') "
    while read -r dep; do
        [[ -z "$dep" ]] && continue
        dep="$(strip_version "$dep")"
        [[ "$own" == *" $dep "* ]] && continue
        ensure "$dep" || die "cannot satisfy '$dep' needed by ${dir##*/}"
    done < <(srcinfo_field "$info" '(make|check)?depends(_x86_64)?')

    stamp="$STAMP_DIR/${dir##*/}"
    local hash
    hash="$(build_key "$dir" "$info")"
    if [[ -f "$stamp" && "$(cat "$stamp")" == "$hash" ]] \
        && in_local_repo "$(srcinfo_field "$info" 'pkgname' | head -n1)"; then
        msg2 "${dir##*/}: unchanged, already in the local repo"
    else
        msg "Building ${dir##*/}"
        prepare_local_version "$dir"
        rm -f "$dir"/*.pkg.tar.*
        if [[ "$BUILD_MODE" == container ]]; then
            (cd "$dir" && MAKEFLAGS="-j$(nproc)" makepkg -sf --noconfirm --needed) || die "build of ${dir##*/} failed"
        else
            ensure_chroot
            (cd "$dir" && sudo makechrootpkg -c -u -r "$CHROOT_DIR" -D "$LOCAL_REPO_DIR" -- --noconfirm) || die "build of ${dir##*/} failed"
        fi
        mapfile -t pkgs < <(find "$dir" -maxdepth 1 -name '*.pkg.tar.zst' ! -name '*-debug-*')
        (( ${#pkgs[@]} )) || die "${dir##*/} produced no packages"
        cp "${pkgs[@]}" "$LOCAL_REPO_DIR/" || die "cannot copy ${dir##*/} packages to $LOCAL_REPO_DIR"
        local added=()
        for p in "${pkgs[@]}"; do
            added+=("$LOCAL_REPO_DIR/${p##*/}")
            rm -f "$LOCAL_REPO_DIR/${p##*/}.sig"   # a rebuilt file needs a fresh signature
        done
        repo-add -q -R "$LOCAL_REPO_DIR/$LOCAL_REPO_NAME.db.tar.gz" "${added[@]}" || die "repo-add failed for ${dir##*/}"
        sync_private_db || die "cannot refresh the package databases"
        touch "$WORK_DIR/.built-something"
        [[ "$BUILD_MODE" == container ]] && { sudo pacman -Sy --noconfirm >/dev/null || die "cannot refresh pacman"; }
        mkdir -p "$STAMP_DIR"
        echo "$hash" > "$stamp" || die "cannot write $stamp"
        [[ "$dir" == "$AUR_DIR"/* ]] && AUR_BUILT+=("${dir##*/}")
    fi

    BUILT[$dir]=1
    unset 'VISITING[$dir]'
}

# Makes sure a dependency is available in the build repos; builds it if needed.
ensure() {
    local dep="$1" dir
    [[ -n "${SATISFIED[$dep]:-}" ]] && return 0
    if [[ -n "${LOCAL_PKG[$dep]:-}" ]]; then
        build_dir "${LOCAL_PKG[$dep]}"
    elif in_repos "$dep"; then
        :
    elif dir="$(aur_fetch "$dep")"; then
        build_dir "$dir"
    else
        return 1
    fi
    SATISFIED[$dep]=1
}

main() {
    render_pacman_conf
    ensure_local_repo
    sync_private_db
    mkdir -p "$AUR_DIR"
    touch "$AUR_LOCK_OUT"
    index_local_pkgbuilds
    container_init
    rm -f "$WORK_DIR/.built-something"
    qt_salt > "$WORK_DIR/qt-version.txt"

    local spec optional alts chosen a resolved=()
    while read -r spec; do
        optional=false
        if [[ "$spec" == *'?' ]]; then
            optional=true
            spec="${spec%\?}"
        fi
        IFS='|' read -ra alts <<< "$spec"
        chosen=""
        for a in "${alts[@]}"; do
            if ensure "$a"; then
                chosen="$a"
                break
            fi
        done
        if [[ -n "$chosen" ]]; then
            resolved+=("$chosen")
        elif $optional; then
            warn "optional package '$spec' not found in the repos or the AUR, skipping"
        else
            die "package '$spec' not found in the repos, pkgbuilds/ or the AUR"
        fi
    done < <(read_list "$ROOT_DIR/packages/system.txt"; read_list "$ROOT_DIR/packages/live.txt")

    printf '%s\n' "${resolved[@]}" > "$RESOLVED_LIST"
    sort -u -o "$AUR_LOCK_OUT" "$AUR_LOCK_OUT"
    if (( ${#AUR_BUILT[@]} )); then
        msg "Built from the AUR: ${AUR_BUILT[*]}"
    fi
    msg "Package list ready: $RESOLVED_LIST (${#resolved[@]} packages)"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
