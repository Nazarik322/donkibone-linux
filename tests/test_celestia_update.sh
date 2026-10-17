#!/usr/bin/env bash
# Behaviour tests of celestia-update and celestia-channel with stub pacman/sudo.
# Run: bash tests/test_celestia_update.sh
BIN="$(cd "$(dirname "$0")/.." && pwd)/pkgbuilds/celestia-system/files/bin"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
mkdir -p "$T/bin"

# sudo: run the command as is (and drop "env VAR=..." wrappers)
cat > "$T/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == env ]] && shift && shift
exec "$@"
EOF
# pacman: logs calls; behaviour chosen by env vars
cat > "$T/bin/pacman" <<'EOF'
#!/usr/bin/env bash
echo "pacman $*" >> "$T_LOG"
case "$*" in
    "-Sy") exit 0 ;;
    "-Su --print --print-format %n")
        if [[ "$QT_HELD" == 1 ]]; then
            echo "error: failed to prepare transaction (could not satisfy dependencies)"
            echo ":: installing qt6-base (6.11.0-1) breaks dependency 'qt6-base=6.10.1' required by quickshell-git"
            exit 1
        elif [[ "$OTHER_FAIL" == 1 ]]; then
            echo "error: failed retrieving file 'core.db' from mirror"; exit 1
        fi
        echo "linux-cachyos"; exit 0 ;;
    "-Su") exit 0 ;;
    "-Qmq") [[ "$FOREIGN" == 1 ]] && echo "some-aur-pkg"; exit 0 ;;
    "-Syuu") [[ "$SWITCH_FAIL" == 1 ]] && exit 1; exit 0 ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\necho paru "$@" >> "$T_LOG"\n' > "$T/bin/paru"
printf '#!/usr/bin/env bash\necho dots-sync >> "$T_LOG"\n' > "$T/bin/celestia-dots-sync"
chmod +x "$T/bin/"*

run() {  # name, "ENV=.. ENV=.." , command..., -- expectations
    local name="$1" envs="$2"; shift 2
    local cmd=()
    while [[ "$1" != "--" ]]; do cmd+=("$1"); shift; done; shift
    : > "$T/log"
    local out
    out="$(env PATH="$T/bin:$PATH" T_LOG="$T/log" QT_HELD=0 OTHER_FAIL=0 FOREIGN=0 SWITCH_FAIL=0 $envs "${cmd[@]}" 2>&1 < /dev/null)"
    local rc=$? all="$(cat "$T/log")"$'\n'"$out" ok=true e
    for e in "$@"; do
        case "$e" in
            !*) [[ "$all" == *"${e:1}"* ]] && ok=false ;;
            rc=*) [[ "$rc" == "${e#rc=}" ]] || ok=false ;;
            *) [[ "$all" == *"$e"* ]] || ok=false ;;
        esac
    done
    if $ok; then echo "PASS $name"; else echo "FAIL $name (rc=$rc)"; echo "$all" | sed 's/^/    /'; fails=1; fi
}

run "update: normal path updates system and dots" "" bash "$BIN/celestia-update" -- \
    "pacman -Su" "dots-sync" "!paru" "rc=0"
run "update: Qt ahead of the shell -> held, nothing updated, clear message" "QT_HELD=1" bash "$BIN/celestia-update" -- \
    "новую версию Qt" "!pacman -Su"$'\n' "!dots-sync" "rc=0"
run "update: other failure is reported, not hidden" "OTHER_FAIL=1" bash "$BIN/celestia-update" -- \
    "core.db" "Обновление невозможно" "rc=1"
run "update: AUR only when foreign packages exist" "FOREIGN=1" bash "$BIN/celestia-update" -- \
    "paru -Sua" "rc=0"

# --- celestia-channel
R="$T/root"; mkdir -p "$R/etc/celestia" "$R/etc/pacman.d"
echo stable > "$R/etc/celestia/channel"; echo "Owner/Repo" > "$R/etc/celestia/repo"
run "channel: shows the current one" "CELESTIA_ROOT=$R" bash "$BIN/celestia-channel" -- "stable" "rc=0"
run "channel: unknown name rejected" "CELESTIA_ROOT=$R" bash "$BIN/celestia-channel" nightly -- "неизвестный канал" "rc=2"
run "channel: switch writes config, allows downgrades" "CELESTIA_ROOT=$R" bash "$BIN/celestia-channel" beta -y -- \
    "pacman -Syuu" "rc=0"
check_conf() { [[ "$(cat "$R/etc/celestia/channel")" == beta ]] && grep -q '^\[celestia-beta\]' "$R/etc/pacman.d/celestia.conf" \
    && grep -q 'Server = https://github.com/Owner/Repo/releases/download/repo-beta' "$R/etc/pacman.d/celestia.conf" \
    && grep -q 'SigLevel = Required' "$R/etc/pacman.d/celestia.conf"; }
if check_conf; then echo "PASS channel: config points at the right signed repo"; else echo "FAIL channel: config"; fails=1; fi
run "channel: failed sync rolls the channel back" "CELESTIA_ROOT=$R SWITCH_FAIL=1" bash "$BIN/celestia-channel" dev -y -- "возвращаю канал beta" "rc=1"
if [[ "$(cat "$R/etc/celestia/channel")" == beta ]] && grep -q '^\[celestia-beta\]' "$R/etc/pacman.d/celestia.conf"; then
    echo "PASS channel: rollback restored channel and config"; else echo "FAIL channel: rollback"; fails=1; fi
run "channel: same channel is a no-op" "CELESTIA_ROOT=$R" bash "$BIN/celestia-channel" beta -- "Уже используется" "!pacman -Syuu" "rc=0"

exit $fails
