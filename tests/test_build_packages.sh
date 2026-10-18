#!/usr/bin/env bash
# Tests of the rebuild logic of scripts/build-packages.sh (build keys, version stamping)
# on a temporary copy of the project. Run: bash tests/test_build_packages.sh
REAL="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=1; fi; }

cp -r "$REAL/scripts" "$REAL/pkgbuilds" "$REAL/packages" "$REAL/config.env" "$T/"
export WORK_DIR="$T/work"; mkdir -p "$WORK_DIR"

# shellcheck disable=SC1091
source "$T/scripts/build-packages.sh"
ROOT_DIR="$T"
AUR_DIR="$T/aur"; LOCAL_BUILD_DIR="$T/build"; PRIVATE_DB="$T/nodb"; BUILD_PACMAN_CONF=/dev/null
celestia_pkgver() { echo "1.${FAKE_COMMITS:-5}"; }
qt_salt() { echo "${FAKE_QT:-6.10.1}"; }   # no pacman database here
mkdir -p "$LOCAL_BUILD_DIR"; cp -r "$T/pkgbuilds/." "$LOCAL_BUILD_DIR/"

key() { build_key "$LOCAL_BUILD_DIR/$1" "${2:-}"; }

check "key is deterministic" '[[ "$(key caelestia-cli)" == "$(key caelestia-cli)" ]]'

before="$(key caelestia-cli)"; echo "# x" >> "$T/pkgbuilds/caelestia-cli/PKGBUILD"
check "key changes when the PKGBUILD changes" '[[ "$(key caelestia-cli)" != "$before" ]]'

check "Qt-pinned package is rebuilt when Qt moves" \
    '[[ "$(FAKE_QT=6.10.1 key quickshell-git)" != "$(FAKE_QT=6.11.0 key quickshell-git)" ]]'
check "package unrelated to Qt ignores Qt" \
    '[[ "$(FAKE_QT=6.10.1 key caelestia-cli)" == "$(FAKE_QT=6.11.0 key caelestia-cli)" ]]'
check "package with qt6-* dependency follows Qt" \
    '[[ "$(FAKE_QT=1 key caelestia-cli "depends = qt6-base")" != "$(FAKE_QT=2 key caelestia-cli "depends = qt6-base")" ]]'
check "celestia-system gets a new key per commit" \
    '[[ "$(FAKE_COMMITS=5 key celestia-system)" != "$(FAKE_COMMITS=6 key celestia-system)" ]]'
check "generated theme files do not change the key" '
    a="$(key celestia-system)"; mkdir -p "$T/pkgbuilds/celestia-system/files/generated"; echo x > "$T/pkgbuilds/celestia-system/files/generated/f"
    [[ "$(key celestia-system)" == "$a" ]]'

prepare_local_version "$LOCAL_BUILD_DIR/celestia-system"
check "celestia-system pkgver = 1.<commits>" 'grep -qx "pkgver=1.5" "$LOCAL_BUILD_DIR/celestia-system/PKGBUILD"'
prepare_local_version "$LOCAL_BUILD_DIR/quickshell-git"
check "Qt-pinned pkgrel = 1.<timestamp>" 'grep -Eq "^pkgrel=1\.[0-9]{12}$" "$LOCAL_BUILD_DIR/quickshell-git/PKGBUILD"'
prepare_local_version "$LOCAL_BUILD_DIR/caelestia-cli"
check "other packages keep their version" 'grep -qx "pkgrel=1" "$LOCAL_BUILD_DIR/caelestia-cli/PKGBUILD"'
check "versions are stamped on build copies only" '! grep -q "pkgver=1.5" "$REAL/pkgbuilds/celestia-system/PKGBUILD"'

exit $fails
