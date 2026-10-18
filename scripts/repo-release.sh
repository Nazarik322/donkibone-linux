#!/usr/bin/env bash
# Hosts the pacman repository of an update channel in a GitHub Release.
#
#   scripts/repo-release.sh restore    download the published repository into the local
#                                      repo dir, so unchanged packages are not rebuilt
#   scripts/repo-release.sh publish    sign and upload new packages, then the database
#
# Release "repo-<channel>" of $CELESTIA_REPO holds, as plain assets (no sub-folders):
#   <name>.pkg.tar.zst + .sig     packages
#   celestia-<channel>.db + .sig  database pacman downloads (and .files)
#   stamps.txt                    build keys of the packages (see build-packages.sh)
#
# Needs: gh (GH_TOKEN), gpg with the signing key, bsdtar. The repository name used by
# pacman is celestia-<channel>, so LOCAL_REPO_NAME must be that (set by the workflow).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CHANNEL="$(detect_channel)"
TAG="repo-$CHANNEL"
REPO_NAME="celestia-$CHANNEL"
STAMP_DIR="$WORK_DIR/stamps"
PREV_REFS="$WORK_DIR/prev-refs.txt"
DB_BASE="$LOCAL_REPO_DIR/$REPO_NAME"

[[ "$LOCAL_REPO_NAME" == "$REPO_NAME" ]] || die "LOCAL_REPO_NAME must be $REPO_NAME for channel $CHANNEL (got $LOCAL_REPO_NAME)"

# Package files a repository database refers to, one per line.
db_refs() {  # <db tarball>
    bsdtar -xOf "$1" '*/desc' 2>/dev/null | awk '/^%FILENAME%$/ {getline; print}'
}

# Which release assets to delete: everything that is neither part of the new database,
# nor of the one it replaces (kept one more round so clients with an older database do
# not hit a 404), nor a repository metadata file.
stale_assets() {  # <assets file> <keep refs file>
    local asset base
    while read -r asset; do
        case "$asset" in
            "$REPO_NAME".db|"$REPO_NAME".db.sig|"$REPO_NAME".files|"$REPO_NAME".files.sig|stamps.txt|qt-version.txt) continue ;;
        esac
        base="${asset%.sig}"
        grep -qxF "$base" "$2" || echo "$asset"
    done < "$1"
}

release_exists() { gh release view "$TAG" -R "$CELESTIA_REPO" >/dev/null 2>&1; }

cmd_restore() {
    mkdir -p "$LOCAL_REPO_DIR" "$STAMP_DIR"
    : > "$PREV_REFS"
    if ! release_exists; then
        msg2 "no release $TAG yet, starting an empty repository"
        return 0
    fi
    msg "Restoring $TAG"
    gh release download "$TAG" -R "$CELESTIA_REPO" -D "$LOCAL_REPO_DIR" --clobber \
        || { warn "download failed, building everything"; return 0; }
    # pacman fetches <repo>.db; repo-add works on <repo>.db.tar.gz
    for kind in db files; do
        if [[ -f "$DB_BASE.$kind" ]]; then
            mv -f "$DB_BASE.$kind" "$DB_BASE.$kind.tar.gz"
            ln -sf "$REPO_NAME.$kind.tar.gz" "$DB_BASE.$kind"
            rm -f "$DB_BASE.$kind.sig"
        fi
    done
    [[ -f "$DB_BASE.db.tar.gz" ]] && db_refs "$DB_BASE.db.tar.gz" > "$PREV_REFS"
    if [[ -f "$LOCAL_REPO_DIR/stamps.txt" ]]; then
        while read -r name hash; do
            [[ -n "$hash" ]] && echo "$hash" > "$STAMP_DIR/$name"
        done < "$LOCAL_REPO_DIR/stamps.txt"
    fi
    msg2 "restored $(wc -l < "$PREV_REFS") package(s)"
}

cmd_publish() {
    local key="${CELESTIA_SIGNING_KEY_ID:?set CELESTIA_SIGNING_KEY_ID to the fingerprint of the signing key}"
    if [[ "${PUBLISH_ONLY_IF_BUILT:-}" == 1 && ! -e "$WORK_DIR/.built-something" ]] && release_exists; then
        msg "Nothing was rebuilt, $TAG stays as it is"
        return 0
    fi
    [[ -f "$DB_BASE.db.tar.gz" ]] || die "no repository database at $DB_BASE.db.tar.gz (nothing built?)"
    cd "$LOCAL_REPO_DIR"

    msg "Signing"
    local pkg
    for pkg in *.pkg.tar.zst; do
        [[ -f "$pkg.sig" ]] || gpg --batch --yes --detach-sign -u "$key" -o "$pkg.sig" "$pkg"
    done
    # the database as pacman downloads it: a real file next to its signature
    rm -f "$REPO_NAME.db" "$REPO_NAME.files" "$REPO_NAME.db.sig" "$REPO_NAME.files.sig"
    cp "$REPO_NAME.db.tar.gz" "$REPO_NAME.db"
    cp "$REPO_NAME.files.tar.gz" "$REPO_NAME.files" 2>/dev/null || true
    gpg --batch --yes --detach-sign -u "$key" -o "$REPO_NAME.db.sig" "$REPO_NAME.db"
    [[ -f "$REPO_NAME.files" ]] && gpg --batch --yes --detach-sign -u "$key" -o "$REPO_NAME.files.sig" "$REPO_NAME.files"

    cp "$WORK_DIR/qt-version.txt" qt-version.txt 2>/dev/null || true
    : > stamps.txt
    local f
    for f in "$STAMP_DIR"/*; do
        [[ -f "$f" ]] && echo "$(basename "$f") $(cat "$f")" >> stamps.txt
    done

    if ! release_exists; then
        msg2 "creating release $TAG"
        local flags=()
        [[ "$CHANNEL" != stable ]] && flags+=(--prerelease)
        gh release create "$TAG" -R "$CELESTIA_REPO" --title "Repository: $CHANNEL" "${flags[@]}" \
            --notes "Signed pacman repository of the $CHANNEL channel. Not meant to be downloaded by hand: see celestia-channel."
    fi

    msg "Uploading (packages first, database last)"
    gh release upload "$TAG" -R "$CELESTIA_REPO" --clobber *.pkg.tar.zst *.pkg.tar.zst.sig
    local meta=(stamps.txt "$REPO_NAME.db" "$REPO_NAME.db.sig")
    [[ -f qt-version.txt ]] && meta+=(qt-version.txt)
    [[ -f "$REPO_NAME.files" ]] && meta+=("$REPO_NAME.files" "$REPO_NAME.files.sig")
    gh release upload "$TAG" -R "$CELESTIA_REPO" --clobber "${meta[@]}"

    msg "Removing superseded files"
    local keep="$WORK_DIR/keep-refs.txt" assets="$WORK_DIR/assets.txt"
    { db_refs "$REPO_NAME.db.tar.gz"; cat "$PREV_REFS" 2>/dev/null; } | sort -u > "$keep"
    gh release view "$TAG" -R "$CELESTIA_REPO" --json assets --jq '.assets[].name' > "$assets"
    stale_assets "$assets" "$keep" | while read -r asset; do
        echo "  - $asset"
        gh release delete-asset "$TAG" "$asset" -R "$CELESTIA_REPO" -y
    done
    msg "Published $TAG: https://github.com/$CELESTIA_REPO/releases/tag/$TAG"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        restore) cmd_restore ;;
        publish) cmd_publish ;;
        *) die "usage: repo-release.sh restore|publish" ;;
    esac
fi
