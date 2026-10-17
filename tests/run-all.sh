#!/usr/bin/env bash
# All offline checks: no root, no disks, no network.
#   bash tests/run-all.sh
# Uses shellcheck when it is installed (pacman -S shellcheck).
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR" || exit 1
PYTHON="${PYTHON:-python3}"
fail=0
step() { echo; echo "== $*"; }

shell_scripts=(
    build.sh scripts/*.sh calamares/scripts/*
    pkgbuilds/celestia-system/files/bin/* pkgbuilds/celestia-system/files/lib/*
    profile/airootfs/usr/local/bin/celestia-installer profile/airootfs/usr/local/bin/celestia-diskpick
    profile/profiledef.sh tests/*.sh
)

step "bash -n"
for f in "${shell_scripts[@]}" pkgbuilds/*/PKGBUILD; do
    bash -n "$f" || { echo "FAIL $f"; fail=1; }
done
echo "checked ${#shell_scripts[@]} scripts + PKGBUILDs"

if command -v shellcheck >/dev/null; then
    step "shellcheck (errors only)"
    shellcheck -S error "${shell_scripts[@]}" || fail=1
fi

step "python syntax"
"$PYTHON" -c "import ast, sys
for p in sys.argv[1:]: ast.parse(open(p, encoding='utf-8').read(), p)
print('ok')" profile/airootfs/usr/local/bin/celestia-disks calamares/modules/celestiadisk/main.py \
    scripts/make_theme.py || fail=1

step "pinned versions"
bash scripts/check-consistency.sh || fail=1

step "celestia-disks (disk safety)"
"$PYTHON" tests/test_celestia_disks.py 2>/dev/null | grep -E "^(FAIL|RESULT)" ; [[ ${PIPESTATUS[0]} -eq 0 ]] || fail=1

step "session-start (lock screen)"
bash tests/test_session_start.sh || fail=1

step "celestia-refind (UEFI boot entry)"
bash tests/test_celestia_refind_nvram.sh || fail=1

echo
if (( fail )); then echo "SOME CHECKS FAILED"; else echo "ALL CHECKS PASSED"; fi
exit $fail
