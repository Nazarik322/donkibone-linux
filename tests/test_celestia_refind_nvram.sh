#!/usr/bin/env bash
# Behaviour test of the UEFI boot entry handling in celestia-refind (own_entry,
# fix_boot_order) with a stub efibootmgr. No firmware access.
# Run: bash tests/test_celestia_refind_nvram.sh
SRC="$(cd "$(dirname "$0")/.." && pwd)/pkgbuilds/celestia-system/files/bin/celestia-refind"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0

sed -n '/^log() /p; /^die() /p; /^own_entry() {/,/^}/p; /^fix_boot_order() {/,/^}/p' "$SRC" > "$T/funcs.sh"

cat > "$T/efibootmgr" <<'EOF'
#!/usr/bin/env bash
echo "efibootmgr $*" >> "$T_LOG"
case "$*" in
    "-v"|"")
        cat "$T_ENTRIES"
        [[ -z "$*" ]] && echo "BootOrder: $(sed -nE 's/^Boot([0-9A-F]{4}).*/\1/p' "$T_ENTRIES" | paste -sd, -)"
        ;;
    *--delete-bootnum*)
        n="$(sed -nE 's/.*--bootnum ([0-9A-F]{4}).*/\1/p' <<< "$*")"
        sed -i "/^Boot$n/d" "$T_ENTRIES"
        ;;
    *--create*)
        cat "$T_NEW_ENTRY" >> "$T_ENTRIES"
        ;;
esac
EOF
chmod +x "$T/efibootmgr"

# Lines exactly as efibootmgr -v prints them (literal backslashes, tab after the label)
cat > "$T/win" <<'EOF'
Boot0001* Windows Boot Manager	HD(1,GPT,aaaa-bbbb,0x800,0x32000)/\EFI\Microsoft\Boot\bootmgfw.efi
EOF
cat > "$T/good" <<'EOF'
Boot0003* Celestia	HD(1,GPT,AAAA-BBBB,0x800,0x64000)/\EFI\refind\refind_x64.efi
EOF
cat > "$T/stale" <<'EOF'
Boot0004* Celestia	HD(2,GPT,cccc-dddd,0x800,0x64000)/\EFI\refind\refind_x64.efi
EOF
cat > "$T/new" <<'EOF'
Boot0009* Celestia	HD(1,GPT,aaaa-bbbb,0x800,0x64000)/\EFI\refind\refind_x64.efi
EOF

run() {  # name, entry files, -- expectations ("!x" = must not appear)
    local name="$1"; shift
    : > "$T/entries"
    while [[ "$1" != "--" ]]; do cat "$T/$1" >> "$T/entries"; shift; done
    shift
    : > "$T/log"
    (
        export PATH="$T:$PATH" T_LOG="$T/log" T_ENTRIES="$T/entries" T_NEW_ENTRY="$T/new"
        EFI_LABEL=Celestia EFI_LOADER='\EFI\refind\refind_x64.efi'
        esp_partuuid=aaaa-bbbb esp_disk=/dev/nvme0n1 esp_part=1
        source "$T/funcs.sh"
        fix_boot_order >/dev/null 2>&1
    )
    local log ok=true e
    log="$(cat "$T/log")"
    for e in "$@"; do
        case "$e" in
            !*) [[ "$log" == *"${e:1}"* ]] && ok=false ;;
            *)  [[ "$log" == *"$e"* ]] || ok=false ;;
        esac
    done
    if $ok; then echo "PASS $name"; else echo "FAIL $name"; echo "$log" | sed 's/^/    /'; fails=1; fi
}

run "valid entry reused, nothing deleted or created" win good -- \
    "--bootorder 0003,0001" "!--delete-bootnum" "!--create"
run "stale entry from another ESP deleted, new one first" win stale -- \
    "--bootnum 0004 --delete-bootnum" "--create" "--bootorder 0009,0001"
run "valid + stale: stale deleted, valid kept" win stale good -- \
    "--bootnum 0004 --delete-bootnum" "!--create" "--bootorder 0003,0001"
run "no entry: created and put first" win -- \
    "--create" "!--delete-bootnum" "--bootorder 0009,0001"
run "Windows entry never deleted" win stale -- \
    "!--bootnum 0001 --delete-bootnum"

exit $fails
