#!/usr/bin/env bash
# Checks that values duplicated across the project agree:
#   - caelestia dots commit: celestia-system and caelestia-firefox-theme PKGBUILDs
#   - caelestia shell release + checksum: PKGBUILD and scripts/make-theme.sh
# Run by build.sh before building and by tests/run-all.sh.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

value() {  # <file> <variable>  -> value of VAR=... (quotes stripped)
    sed -nE "s/^[[:space:]]*$2=['\"]?([^'\" ]*)['\"]?.*/\1/p" "$ROOT_DIR/$1" | head -n1
}
sha_of() {  # first entry of sha256sums=('...') in a PKGBUILD
    sed -nE "s/^sha256sums=\('([0-9a-f]+)'.*/\1/p" "$ROOT_DIR/$1" | head -n1
}

fail=0
same() {  # <description> <a> <b>
    if [[ -z "$2" || "$2" != "$3" ]]; then
        echo "MISMATCH $1: '$2' vs '$3'" >&2
        fail=1
    else
        echo "ok       $1 ($2)"
    fi
}

same "dots commit (celestia-system vs caelestia-firefox-theme)" \
    "$(value pkgbuilds/celestia-system/PKGBUILD _dots_commit)" \
    "$(value pkgbuilds/caelestia-firefox-theme/PKGBUILD _dots_commit)"
same "caelestia-shell version (PKGBUILD vs make-theme.sh)" \
    "$(value pkgbuilds/caelestia-shell/PKGBUILD pkgver)" \
    "$(value scripts/make-theme.sh SHELL_VERSION)"
same "caelestia-shell sha256 (PKGBUILD vs make-theme.sh)" \
    "$(sha_of pkgbuilds/caelestia-shell/PKGBUILD)" \
    "$(value scripts/make-theme.sh SHELL_SHA256)"

exit $fail
