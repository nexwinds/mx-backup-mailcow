#!/usr/bin/env bash
# Release packaging: archive layout, checksum manifests and version consistency.
set -uo pipefail
source "$(dirname "$0")/lib/helpers.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mxb-release.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

begin "build a release archive"
run bash "$BUILDER" --source "$REPO_ROOT" --out "$WORK/out" --version 2.3.4
assert_status 0 "build should succeed"
archive="$WORK/out/mx-backup-mailcow-2.3.4.tar.gz"
assert_file "$archive" "archive created"
assert_file "$WORK/out/SHA256SUMS" "asset manifest created"
assert_file "$WORK/out/install.sh" "installer asset created"

begin "standalone installer reports the release version"
run bash "$WORK/out/install.sh" --version
assert_status 0 "standalone installer --version should succeed"
assert_contains "$LAST_OUTPUT" "install 2.3.4" "standalone installer must embed VERSION"

listing=$(tar -tzf "$archive")
for entry in \
    "mx-backup-mailcow-2.3.4/bin/install.sh" \
    "mx-backup-mailcow-2.3.4/bin/sync-mailcow.sh" \
    "mx-backup-mailcow-2.3.4/bin/update.sh" \
    "mx-backup-mailcow-2.3.4/bin/diagnose.sh" \
    "mx-backup-mailcow-2.3.4/bin/update-scripts.sh" \
    "mx-backup-mailcow-2.3.4/VERSION" \
    "mx-backup-mailcow-2.3.4/SHA256SUMS" \
    "mx-backup-mailcow-2.3.4/systemd/mailcow-sync.service" \
    "mx-backup-mailcow-2.3.4/systemd/mailcow-sync.timer" \
    "mx-backup-mailcow-2.3.4/share/doc/README.md" \
    "mx-backup-mailcow-2.3.4/config/config.example" \
    "mx-backup-mailcow-2.3.4/logrotate/mailcow-backup-mx"; do
    assert_contains "$listing" "$entry" "archive contains $entry"
done

begin "archive has no unsafe paths"
assert_not_contains "$listing" "../" "no parent-directory entries"
assert_not_contains "$listing" " /" "no absolute entries"

begin "version is consistent"
extract="$WORK/extract"
mkdir -p "$extract"
tar -xzf "$archive" -C "$extract"
assert_eq "$(cat "$extract/mx-backup-mailcow-2.3.4/VERSION")" "2.3.4" "VERSION matches the release"
assert_eq "$(cat "$WORK/out/SHA256SUMS" | wc -l | tr -d ' ')" "2" "asset manifest lists archive and installer"

begin "inner manifest verifies every file"
run bash -c "cd '$extract/mx-backup-mailcow-2.3.4' && sha256sum -c SHA256SUMS --quiet"
assert_status 0 "inner checksums must verify"

begin "outer manifest verifies the archive"
expected=$(awk '/mx-backup-mailcow-2.3.4.tar.gz/ {print $1}' "$WORK/out/SHA256SUMS")
actual=$(sha256sum "$archive" | awk '{print $1}')
assert_eq "$actual" "$expected" "archive checksum matches the manifest"

begin "outer manifest verifies the published files"
run bash -c "cd '$WORK/out' && sha256sum -c SHA256SUMS --quiet"
assert_status 0 "asset checksums must verify with sha256sum -c"

begin "invalid versions are refused"
run bash "$BUILDER" --source "$REPO_ROOT" --out "$WORK/bad" --version "2.3"
assert_status 1 "invalid semantic version must be refused"

begin "missing source files are refused"
mkdir -p "$WORK/empty"
run bash "$BUILDER" --source "$WORK/empty" --out "$WORK/empty-out" --version 1.0.0
assert_status 1 "incomplete source tree must be refused"

finish
