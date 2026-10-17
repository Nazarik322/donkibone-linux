# Shared helpers for the build scripts. Usage: source "$(dirname "$0")/common.sh"
# shellcheck shell=bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config.env
source "$ROOT_DIR/config.env"

BUILD_PACMAN_CONF="$WORK_DIR/pacman.conf"
PRIVATE_DB="$WORK_DIR/pacman-db"
RESOLVED_LIST="$WORK_DIR/packages.resolved"
OFFLINE_REPO_DIR="$WORK_DIR/offline-repo"
OFFLINE_REPO_NAME="celestia-offline"

# Update channel of a git branch: main -> stable, beta -> beta, anything else -> dev.
channel_of_branch() {
    case "$1" in
        main|master) echo stable ;;
        beta)        echo beta ;;
        *)           echo dev ;;
    esac
}

# The channel this build belongs to (config.env, else the current git branch).
detect_channel() {
    local ch="$CELESTIA_CHANNEL" branch
    if [[ -z "$ch" ]]; then
        branch="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
        ch="$(channel_of_branch "${GITHUB_REF_NAME:-${branch:-main}}")"
    fi
    case "$ch" in stable|beta|dev) echo "$ch" ;; *) die "unknown channel '$ch' (stable|beta|dev)" ;; esac
}

# Monotonic package version of our own packages: 1.<number of commits>.
celestia_pkgver() {
    echo "1.$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 0)"
}

# pacman repository section for a channel (Include file of the installed system).
render_channel_conf() {  # <channel>
    cat <<CONF
# Celestia update channel: $1  (change with: sudo celestia-channel stable|beta|dev)
[celestia-$1]
SigLevel = Required DatabaseOptional
Server = https://github.com/$CELESTIA_REPO/releases/download/repo-$1
CONF
}

msg()  { printf '\033[1;35m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
msg2() { printf '\033[1;34m  ->\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Package specs from a list file: comments and blank lines removed.
read_list() {
    sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' "$1"
}

# Resolves the @MARCH markers of a pacman.conf in place according to CACHYOS_MARCH:
#   v3      CachyOS x86-64-v3 repos (default)
#   generic no optimized repos, runs on any x86-64 CPU
apply_march() {
    case "$CACHYOS_MARCH" in
        v3)      sed -i 's/[[:space:]]*# @MARCH_ARCH$//; /# @MARCH_V3_/d' "$1" ;;
        generic) sed -i 's/^Architecture = .*# @MARCH_ARCH$/Architecture = x86_64/;
                         /# @MARCH_V3_BEGIN/,/# @MARCH_V3_END/d' "$1" ;;
        *)       die "CACHYOS_MARCH must be 'v3' or 'generic' (config.env), got '$CACHYOS_MARCH'" ;;
    esac
}

# pacman.conf for building: profile/pacman.conf with the local repo path filled in.
render_pacman_conf() {
    mkdir -p "$WORK_DIR"
    sed "s|@LOCAL_REPO_DIR@|$LOCAL_REPO_DIR|g; s|@LOCAL_REPO_NAME@|$LOCAL_REPO_NAME|g" \
        "$ROOT_DIR/profile/pacman.conf" > "$BUILD_PACMAN_CONF"
    apply_march "$BUILD_PACMAN_CONF"
}

# Private sync databases, so lookups never touch the host's own pacman state.
sync_private_db() {
    mkdir -p "$PRIVATE_DB"
    sudo pacman --config "$BUILD_PACMAN_CONF" --dbpath "$PRIVATE_DB" -Sy >/dev/null
}

# True if a package (or something providing it) exists in the build repos.
in_repos() {
    pacman --config "$BUILD_PACMAN_CONF" --dbpath "$PRIVATE_DB" -Sp --print-format '%n' "$1" &>/dev/null
}

ensure_local_repo() {
    local db="$LOCAL_REPO_DIR/$LOCAL_REPO_NAME.db.tar.gz"
    [[ -d "$LOCAL_REPO_DIR" ]] || die "$LOCAL_REPO_DIR is missing, run scripts/setup-build-env.sh first"
    if [[ ! -e "$db" ]]; then
        # An empty but valid repo database (repo-add refuses to run without packages).
        tar -czf "$db" -T /dev/null
        ln -sf "$LOCAL_REPO_NAME.db.tar.gz" "$LOCAL_REPO_DIR/$LOCAL_REPO_NAME.db"
    fi
}
