#!/usr/bin/env bash
# Tests of the asset clean-up rule of scripts/repo-release.sh (which release assets may
# be deleted after a publish). Run: bash tests/test_repo_release.sh
REAL="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=1; fi; }

export WORK_DIR="$T/work" LOCAL_REPO_DIR="$T/repo" LOCAL_REPO_NAME="celestia-dev" CELESTIA_CHANNEL=dev
mkdir -p "$WORK_DIR" "$LOCAL_REPO_DIR"
# shellcheck disable=SC1091
source "$REAL/scripts/repo-release.sh"

cat > "$T/assets" <<'EOF'
celestia-dev.db
celestia-dev.db.sig
celestia-dev.files
celestia-dev.files.sig
stamps.txt
quickshell-git-0.3.0-1.2026.pkg.tar.zst
quickshell-git-0.3.0-1.2026.pkg.tar.zst.sig
quickshell-git-0.3.0-1.2025.pkg.tar.zst
quickshell-git-0.3.0-1.2025.pkg.tar.zst.sig
quickshell-git-0.3.0-1.2024.pkg.tar.zst
quickshell-git-0.3.0-1.2024.pkg.tar.zst.sig
celestia-system-1.9-1-any.pkg.tar.zst
celestia-system-1.9-1-any.pkg.tar.zst.sig
EOF
# the new database refers to the 2026 build; the database it replaces to the 2025 one
printf 'quickshell-git-0.3.0-1.2026.pkg.tar.zst\ncelestia-system-1.9-1-any.pkg.tar.zst\n' > "$T/keep"
printf 'quickshell-git-0.3.0-1.2025.pkg.tar.zst\n' >> "$T/keep"

out="$(stale_assets "$T/assets" "$T/keep")"
check "two-builds-old package and its signature are deleted" \
    '[[ "$out" == *quickshell-git-0.3.0-1.2024.pkg.tar.zst* && "$out" == *quickshell-git-0.3.0-1.2024.pkg.tar.zst.sig* ]]'
check "current package is kept" '[[ "$out" != *2026* ]]'
check "previous package is kept one more round (older clients)" '[[ "$out" != *2025* ]]'
check "metadata is never deleted" '[[ "$out" != *celestia-dev.db* && "$out" != *stamps.txt* && "$out" != *.files* ]]'
check "exactly the stale pair is deleted" '[[ "$(wc -l <<< "$out")" -eq 2 ]]'
check "refuses a mismatching repository name" '(LOCAL_REPO_NAME=celestia WORK_DIR="$T/w2" bash -c "source $REAL/scripts/repo-release.sh" >/dev/null 2>&1; [[ $? -ne 0 ]])'

exit $fails
