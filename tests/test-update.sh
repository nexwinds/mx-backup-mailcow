#!/usr/bin/env bash
# Ubuntu package updates: success, failure, dry run, reboot detection, safety.
set -uo pipefail
source "$(dirname "$0")/lib/helpers.sh"

sandbox_init
trap sandbox_destroy EXIT

begin "successful package update"
run bash "$UPDATE"
assert_status 0 "update should succeed"
assert_eq "$(json_get "$MXB_STATE_DIR/state/update-state.json" '.status')" "ok" "status"
assert_contains "$(json_get "$MXB_STATE_DIR/state/update-state.json" '.summary')" "3 upgraded" "summary captured"
assert_contains "$(cat "$MOCK_DIR/calls.log")" "apt-get update" "apt-get update must run"
assert_contains "$(cat "$MOCK_DIR/calls.log")" "--with-new-pkgs upgrade" "normal upgrade with new packages"
assert_not_contains "$(cat "$MOCK_DIR/calls.log")" "dist-upgrade" "no distribution upgrade"
assert_not_contains "$(cat "$MOCK_DIR/calls.log")" "reboot" "no reboot"
assert_not_contains "$(cat "$MOCK_DIR/calls.log")" "do-release-upgrade" "no release upgrade"

begin "a stale update lock is reclaimed"
mkdir -p "$MXB_STATE_DIR/run/update.lock"
printf '999999\n' >"$MXB_STATE_DIR/run/update.lock/pid"
run bash "$UPDATE"
assert_status 0 "update with a stale lock should succeed"
assert_no_file "$MXB_STATE_DIR/run/update.lock" "the update lock must be removed after success"

begin "dry run simulates and changes nothing"
mock_clear_calls
run bash "$UPDATE" --dry-run
assert_status 0 "dry run should succeed"
assert_contains "$(cat "$MOCK_DIR/calls.log")" "apt-get -s" "simulation flag used"
assert_not_contains "$(cat "$MOCK_DIR/calls.log")" "-y" "no confirmation flag in dry run"
assert_eq "$(json_get "$MXB_STATE_DIR/state/update-state.json" '.dry_run')" "true" "state records dry run"

begin "failed update is reported"
MOCK_APT_FAIL=1
run bash "$UPDATE"
assert_status 1 "update should fail"
assert_eq "$(json_get "$MXB_STATE_DIR/state/update-state.json" '.status')" "failed" "failure status"
assert_contains "$(cat "$MXB_STATE_DIR/state/update-state.json")" "Failed to fetch" "failure details recorded"
assert_contains "$LAST_OUTPUT" "update failed" "failure reported to the operator"
export MOCK_APT_FAIL=0

begin "reboot requirement is detected but never executed"
touch "$MXB_REBOOT_MARKER"
printf 'linux-image-generic\nlibssl3\n' >"$MXB_REBOOT_PKGS"
run bash "$UPDATE"
assert_status 0 "update still succeeds"
assert_eq "$(json_get "$MXB_STATE_DIR/state/update-state.json" '.reboot_required')" "true" "reboot flag"
assert_contains "$(json_get "$MXB_STATE_DIR/state/update-state.json" '.reboot_packages[0]')" "libssl3" "reboot packages recorded"
assert_contains "$LAST_OUTPUT" "reboot required" "reboot reported"
assert_not_contains "$(cat "$MOCK_DIR/calls.log")" "reboot" "no reboot command"
rm -f "$MXB_REBOOT_MARKER" "$MXB_REBOOT_PKGS"

begin "quiet mode writes only to the log"
run bash "$UPDATE" --quiet
assert_status 0 "quiet update should succeed"
assert_not_contains "$LAST_OUTPUT" "starting Ubuntu package update" "no console output"
assert_contains "$(cat "$MXB_LOG_DIR/update.log")" "starting Ubuntu package update" "log still written"

finish
