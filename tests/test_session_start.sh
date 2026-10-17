#!/usr/bin/env bash
# Behaviour test of session-start with stub qs/hyprlock/loginctl (no real session needed).
# Run: bash tests/test_session_start.sh
SRC="$(cd "$(dirname "$0")/.." && pwd)/pkgbuilds/celestia-system/files/lib/session-start"
fails=0

run_case() {  # name, QS_READY_AFTER(s|never), QS_CAN_LOCK(1|0), HYPRLOCK(run|fail|unlock), expect...
    local name="$1"; shift
    local T; T="$(mktemp -d)"
    mkdir -p "$T/bin" "$T/run"
    cat > "$T/bin/qs" <<EOF
#!/usr/bin/env bash
now=\$(date +%s%N); start=\$(cat "$T/start")
[[ "$QS_READY_AFTER" == never ]] && exit 1
(( (now - start) / 1000000 >= $QS_READY_AFTER * 1000 )) || exit 1
case "\$*" in
  *"lock isLocked") cat "$T/locked" 2>/dev/null || echo false ;;
  *"lock lock") echo QS_LOCK_CALL >> "$T/log"; [[ "$QS_CAN_LOCK" == 1 ]] && echo true > "$T/locked" ;;
esac
EOF
    cat > "$T/bin/hyprlock" <<EOF
#!/usr/bin/env bash
echo "hyprlock \$*" >> "$T/log"
case "$HYPRLOCK" in
  run) exec sleep 60 ;;
  fail) exit 1 ;;
  unlock) sleep 0.5; exit 0 ;;
esac
EOF
    printf '#!/usr/bin/env bash\necho terminate >> "%s/log"\n' "$T" > "$T/bin/loginctl"
    printf '#!/usr/bin/env bash\necho firstboot >> "%s/log"\n' "$T" > "$T/bin/firstboot"
    printf '#!/usr/bin/env bash
echo dots-sync >> "%s/log"
' "$T" > "$T/bin/celestia-dots-sync"
    chmod +x "$T/bin/"*
    sed -e "s|/usr/lib/celestia/firstboot|$T/bin/firstboot|g" -e 's/seq 300/seq 30/' "$SRC" > "$T/ss"
    date +%s%N > "$T/start"
    PATH="$T/bin:$PATH" XDG_RUNTIME_DIR="$T/run" timeout 20 bash "$T/ss"; sleep 1.5
    local log; log="$(tr '\n' ' ' < "$T/log" 2>/dev/null)"
    local ok=true
    for exp in "$@"; do
        case "$exp" in
            !*) [[ "$log" == *"${exp:1}"* ]] && ok=false ;;
            *)  [[ "$log" == *"$exp"* ]] || ok=false ;;
        esac
    done
    $ok && echo "PASS $name" || { echo "FAIL $name   log: $log"; fails=1; }
    pkill -f "sleep 60" 2>/dev/null
    rm -rf "$T"
}

QS_READY_AFTER=1 QS_CAN_LOCK=1 HYPRLOCK=run run_case "shell up: hyprlock first, handed over to caelestia" "hyprlock" "QS_LOCK_CALL" "firstboot" "dots-sync" "!terminate"
QS_READY_AFTER=never QS_CAN_LOCK=1 HYPRLOCK=run run_case "no shell: hyprlock stays, session not ended" "hyprlock" "firstboot" "!QS_LOCK_CALL" "!terminate"
QS_READY_AFTER=1 QS_CAN_LOCK=1 HYPRLOCK=fail run_case "hyprlock broken: caelestia locks" "QS_LOCK_CALL" "!terminate"
QS_READY_AFTER=never QS_CAN_LOCK=1 HYPRLOCK=fail run_case "nothing works: session ended (fail closed)" "terminate"
QS_READY_AFTER=2 QS_CAN_LOCK=1 HYPRLOCK=unlock run_case "user unlocked hyprlock first: no relock" "firstboot" "!QS_LOCK_CALL" "!terminate"
QS_READY_AFTER=1 QS_CAN_LOCK=0 HYPRLOCK=run run_case "caelestia cannot lock: hyprlock relocks" "QS_LOCK_CALL" "!terminate"
exit $fails
