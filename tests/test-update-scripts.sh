#!/usr/bin/env bash
# GitHub release updates: verification, self-update, rollback and safety.
set -uo pipefail
source "$(dirname "$0")/lib/helpers.sh"

sandbox_init
trap sandbox_destroy EXIT

begin "install a base version"
installed_app_fixture 1.0.0
export MOCK_GH_LATEST=9.9.9
RELEASE_999=$(prepare_release 9.9.9)
export MOCK_RELEASE_DIR="$RELEASE_999"
assert_eq "$(cat "$MXB_INSTALL_DIR/VERSION")" "1.0.0" "base version"

begin "update check reports the available release"
run bash "$UPDATE_SCRIPTS" --check
assert_status 0 "check should succeed"
assert_contains "$LAST_OUTPUT" "installed 1.0.0" "installed version reported"
assert_contains "$LAST_OUTPUT" "latest 9.9.9" "latest version reported"
assert_contains "$LAST_OUTPUT" "update-available" "update flagged"

begin "a stale updater lock is reclaimed"
mkdir -p "$MXB_STATE_DIR/run/scripts-update.lock"
printf '999999\n' >"$MXB_STATE_DIR/run/scripts-update.lock/pid"
run bash "$UPDATE_SCRIPTS" --check
assert_status 0 "check with a stale lock should succeed"
assert_no_file "$MXB_STATE_DIR/run/scripts-update.lock" "the updater lock must be removed after success"

begin "dry run verifies the release without installing it"
run bash "$UPDATE_SCRIPTS" --release 9.9.9 --dry-run
assert_status 0 "dry run should succeed"
assert_contains "$LAST_OUTPUT" "would install version 9.9.9" "dry-run message"
assert_eq "$(cat "$MXB_INSTALL_DIR/VERSION")" "1.0.0" "version unchanged"
assert_eq "$(mock_calls_count 'postfix reload')" "0" "Postfix must never be reloaded"

begin "checksum mismatch is rejected"
RELEASE_910=$(prepare_release 9.9.10)
export MOCK_RELEASE_DIR="$RELEASE_910"
MOCK_CORRUPT_ASSET=1
run bash "$UPDATE_SCRIPTS" --release 9.9.10 --yes
assert_status 1 "corrupted archive must be rejected"
assert_contains "$LAST_OUTPUT" "checksum mismatch" "checksum error"
assert_eq "$(cat "$MXB_INSTALL_DIR/VERSION")" "1.0.0" "version unchanged"
export MOCK_CORRUPT_ASSET=0

begin "invalid scripts are rejected before installation"
BROKEN=$(prepare_broken_release 9.9.11)
export MOCK_RELEASE_DIR="$BROKEN"
run bash "$UPDATE_SCRIPTS" --release 9.9.11 --yes
assert_status 1 "invalid script must be rejected"
assert_contains "$LAST_OUTPUT" "invalid script" "syntax error reported"
assert_eq "$(cat "$MXB_INSTALL_DIR/VERSION")" "1.0.0" "version unchanged"

begin "install a newer release"
export MOCK_RELEASE_DIR="$RELEASE_999"
run bash "$UPDATE_SCRIPTS" --release 9.9.9 --yes
assert_status 0 "update should succeed"
assert_eq "$(cat "$MXB_INSTALL_DIR/VERSION")" "9.9.9" "new version installed"
assert_eq "$(json_get "$MXB_STATE_DIR/state/update-scripts-state.json" '.action')" "update" "state action"
assert_eq "$(json_get "$MXB_STATE_DIR/state/update-scripts-state.json" '.installed_version')" "9.9.9" "state version"
assert_eq "$(json_get "$MXB_STATE_DIR/state/update-scripts-state.json" '.previous_version')" "1.0.0" "previous version recorded"
assert_file "$MXB_SYSTEMD_DIR/mailcow-sync.timer" "unit installed"
assert_eq "$(mock_get_unit_state mailcow-sync.timer)" "enabled" "timer enabled"
assert_eq "$(find "$MXB_BACKUP_DIR" -maxdepth 1 -type d -name 'app-*-1.0.0' | wc -l | tr -d ' ')" "1" "previous version backed up"
assert_contains "$(cat "$MXB_LOG_DIR/update-scripts.log")" "post-update verification passed" "self-update verified"
assert_eq "$(mock_calls_count 'postfix reload')" "0" "Postfix must never be reloaded"
assert_eq "$(mock_calls_count 'systemctl restart')" "0" "services must not be restarted"
assert_contains "$(cat "$MOCK_DIR/calls.log")" "systemctl daemon-reload" "systemd reloaded for unit changes"

begin "release list is available"
run bash "$UPDATE_SCRIPTS" --list
assert_status 0 "list should succeed"
assert_contains "$LAST_OUTPUT" "v9.9.9" "releases listed"

begin "rollback restores the previous version"
run bash "$UPDATE_SCRIPTS" --rollback --yes
assert_status 0 "rollback should succeed"
assert_eq "$(cat "$MXB_INSTALL_DIR/VERSION")" "1.0.0" "previous version restored"
assert_eq "$(json_get "$MXB_STATE_DIR/state/update-scripts-state.json" '.action')" "rollback" "rollback recorded"
assert_eq "$(json_get "$MXB_STATE_DIR/state/update-scripts-state.json" '.installed_version')" "1.0.0" "rollback version"

begin "configuration, maps and logs are never touched"
assert_file "$MXB_CONFIG_FILE" "configuration preserved"
assert_file "$MXB_LOG_DIR/update-scripts.log" "logs preserved"

begin "the updater uses no authentication token and never touches Postfix"
content=$(cat "$UPDATE_SCRIPTS")
assert_not_contains "$content" "Authorization:" "no authorization header"
assert_not_contains "$content" "dist-upgrade" "no distribution upgrade"
assert_not_contains "$content" "postfix reload" "no Postfix reload"
assert_not_contains "$content" "postqueue -f" "no queue flush"
assert_not_contains "$content" "systemctl restart" "no service restart"

finish
