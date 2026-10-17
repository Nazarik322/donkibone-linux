#!/usr/bin/env bash
# Tests of channel detection and the repository section written for installed systems.
# Run: bash tests/test_channels.sh
REAL="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=1; fi; }
export WORK_DIR="$T/w"
# shellcheck disable=SC1091
source "$REAL/scripts/common.sh"

check "main -> stable" '[[ "$(channel_of_branch main)" == stable ]]'
check "beta -> beta" '[[ "$(channel_of_branch beta)" == beta ]]'
check "dev -> dev" '[[ "$(channel_of_branch dev)" == dev ]]'
check "feature branches -> dev" '[[ "$(channel_of_branch feature/x)" == dev ]]'
check "explicit channel wins over the branch" '[[ "$(CELESTIA_CHANNEL=beta GITHUB_REF_NAME=main detect_channel)" == beta ]]'
check "CI branch name is used" '[[ "$(CELESTIA_CHANNEL= GITHUB_REF_NAME=beta detect_channel)" == beta ]]'
check "unknown explicit channel is an error" '! (CELESTIA_CHANNEL=nightly detect_channel) >/dev/null 2>&1'

conf="$(CELESTIA_REPO=Me/Repo render_channel_conf beta)"
check "repo section name" 'grep -qx "\[celestia-beta\]" <<< "$conf"'
check "signatures required" 'grep -qx "SigLevel = Required" <<< "$conf"'
check "release URL of the channel" 'grep -qx "Server = https://github.com/Me/Repo/releases/download/repo-beta" <<< "$conf"'
check "shipped keyring matches the fingerprint file" \
    '[[ "$(cat "$REAL/pkgbuilds/celestia-keyring/celestia-trusted")" == "$(cat "$REAL/keys/FINGERPRINT"):4:" ]]'
exit $fails
