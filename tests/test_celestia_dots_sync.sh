#!/usr/bin/env bash
# Behaviour test of celestia-dots-sync with a temporary HOME and package tree.
# Run: bash tests/test_celestia_dots_sync.sh
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/pkgbuilds/celestia-system/files/bin/celestia-dots-sync"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1"; fails=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

SRC="$T/src"; export HOME="$T/home"; export CELESTIA_DOTS_SRC="$SRC"
export XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$SRC/.config/hypr" "$SRC/.config/fish" "$HOME"
put() { printf '%s\n' "$2" > "$SRC/$1"; }
sync() { bash "$SCRIPT" "$@" >/dev/null 2>&1; }

# 1. fresh home: files installed
put .config/hypr/a.lua "a v1"; put .config/fish/config.fish "fish v1"
sync
check "fresh home: files installed" '[[ "$(cat $HOME/.config/hypr/a.lua)" == "a v1" && -f $HOME/.config/fish/config.fish ]]'

# 2. package updated, user did not touch -> replaced
put .config/hypr/a.lua "a v2"
sync
check "untouched file is updated" '[[ "$(cat $HOME/.config/hypr/a.lua)" == "a v2" ]]'

# 3. user edits, package updates -> kept, .celestia-new offered
echo "my change" > "$HOME/.config/fish/config.fish"
put .config/fish/config.fish "fish v2"
sync
check "user-modified file is kept" '[[ "$(cat $HOME/.config/fish/config.fish)" == "my change" ]]'
check "new version offered as .celestia-new" '[[ "$(cat $HOME/.config/fish/config.fish.celestia-new)" == "fish v2" ]]'
check "conflict listed" 'grep -q config.fish "$XDG_STATE_HOME/celestia/dots-conflicts.txt"'

# 4. user deleted a file on purpose -> not brought back
rm "$HOME/.config/hypr/a.lua"
put .config/hypr/a.lua "a v3"
sync
check "deleted file stays deleted" '[[ ! -e $HOME/.config/hypr/a.lua ]]'

# 5. new file in the package -> installed
put .config/hypr/b.lua "b v1"
sync
check "new package file is installed" '[[ "$(cat $HOME/.config/hypr/b.lua)" == "b v1" ]]'

# 6. user-owned files (not in the package tree) are never touched
mkdir -p "$HOME/.config/caelestia"; echo "mine" > "$HOME/.config/caelestia/hypr-user.lua"
sync
check "files outside the package tree untouched" '[[ "$(cat $HOME/.config/caelestia/hypr-user.lua)" == "mine" ]]'

# 7. user merges the change by hand (now identical to package): .celestia-new removed, tracked again
cp "$SRC/.config/fish/config.fish" "$HOME/.config/fish/config.fish"
sync
check "merged file: .celestia-new cleaned up" '[[ ! -e $HOME/.config/fish/config.fish.celestia-new ]]'
put .config/fish/config.fish "fish v3"
sync
check "merged file follows the package again" '[[ "$(cat $HOME/.config/fish/config.fish)" == "fish v3" ]]'

# 8. --baseline on a fresh install: identical files recorded, so next update applies
rm -rf "$HOME" "$XDG_STATE_HOME"; mkdir -p "$HOME/.config/hypr"
put .config/hypr/a.lua "a v1"; rm -f "$SRC/.config/hypr/b.lua" "$SRC/.config/fish/config.fish"
cp "$SRC/.config/hypr/a.lua" "$HOME/.config/hypr/a.lua"       # as copied from /etc/skel
sync --baseline
put .config/hypr/a.lua "a v2"
sync
check "baseline: later update is applied" '[[ "$(cat $HOME/.config/hypr/a.lua)" == "a v2" ]]'

# 9. --baseline never claims a modified file as untouched
rm -rf "$HOME" "$XDG_STATE_HOME"; mkdir -p "$HOME/.config/hypr"
put .config/hypr/a.lua "a v1"
echo "edited before baseline" > "$HOME/.config/hypr/a.lua"
sync --baseline
put .config/hypr/a.lua "a v2"
sync
check "baseline: modified file is not overwritten" '[[ "$(cat $HOME/.config/hypr/a.lua)" == "edited before baseline" ]]'

exit $fails
