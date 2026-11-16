#!/usr/bin/env bash
# Mailcow allowlist: postscreen entry, rspamd greylist bypass, drift and undo.
set -uo pipefail
source "$(dirname "$0")/lib/helpers.sh"

ALLOWLIST="$REPO_ROOT/mailcow/allowlist-backup-mx.sh"

sandbox_init
trap sandbox_destroy EXIT

CIDR=""
SETTINGS=""
set_paths() {
    CIDR="$MAILCOW_DIR/data/conf/postfix/custom_postscreen_whitelist.cidr"
    SETTINGS="$MAILCOW_DIR/data/conf/rspamd/local.d/settings.conf"
}
set_paths

run_allowlist() { run bash "$ALLOWLIST" "$@"; }

fresh_sandbox() {
    sandbox_destroy
    sandbox_init
    set_paths
}

begin "the backup MX is allowlisted in postscreen and rspamd"
run_allowlist --ip 188.245.221.122
assert_status 0 "the first run must succeed"
assert_file "$CIDR" "the postscreen whitelist must be created"
assert_eq "$(grep -c '^188\.245\.221\.122/32[[:space:]]*permit$' "$CIDR")" "1" \
    "the network must be permitted"
assert_contains "$(cat "$CIDR")" "BEGIN mx-backup-mailcow" "the block must be marked"
assert_file "$SETTINGS" "the rspamd settings file must be created"
assert_contains "$(cat "$SETTINGS")" "mx_backup_mailcow_greylist" "the rule must exist"
assert_contains "$(cat "$SETTINGS")" '"188.245.221.122/32"' "the rule must match the address"
assert_contains "$(cat "$SETTINGS")" "greylist = null;" "only greylisting must be disabled"
assert_not_contains "$(cat "$SETTINGS")" "want_spam" "spam filtering must stay enabled"
assert_not_contains "$(cat "$SETTINGS")" "groups_disabled" "no other checks may be disabled"
assert_file "$MXB_ALLOWLIST_STATE" "the address list must be saved"
assert_mode "$MXB_ALLOWLIST_STATE" "600" "the saved list must be private"
assert_eq "$(mock_calls_count 'restart rspamd-mailcow')" "1" "rspamd must restart once"
assert_eq "$(mock_calls_count 'postfix reload')" "1" "Postfix must reload once"
assert_eq "$(mock_calls_count "postmap -q 188.245.221.122 cidr:/opt/postfix/conf/custom_postscreen_whitelist.cidr")" "1" \
    "the entry must be verified through Postfix"
assert_contains "$LAST_OUTPUT" "Mailcow now trusts 188.245.221.122/32" "the result must be reported"

begin "the IPv6 syntax of the entry is valid"
assert_contains "$(cat "$SETTINGS")" "ip = [" "the rule must use an address list"

begin "re-running with no arguments repairs nothing and restarts nothing"
backups_before=$(find "$MXB_ALLOWLIST_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
mock_clear_calls
run_allowlist
assert_status 0 "the second run must succeed"
assert_contains "$LAST_OUTPUT" "already applied" "the run must be a no-op"
assert_eq "$(mock_calls_count 'restart rspamd-mailcow')" "0" "rspamd must not restart"
assert_eq "$(mock_calls_count 'postfix reload')" "0" "Postfix must not reload"
assert_eq "$(find "$MXB_ALLOWLIST_BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" \
    "$backups_before" "a no-op must not create a backup directory"

begin "--check reports drift and the next run repairs it"
rm -f "$SETTINGS"
mock_clear_calls
run_allowlist --check
assert_status 1 "drift must exit non-zero"
assert_contains "$LAST_OUTPUT" "drift in" "the drift must be named"
assert_eq "$(mock_calls_count 'restart rspamd-mailcow')" "0" "check must not restart services"
run_allowlist
assert_status 0 "the repair run must succeed"
assert_contains "$(cat "$SETTINGS")" "mx_backup_mailcow_greylist" "the rule must be restored"
assert_eq "$(mock_calls_count 'restart rspamd-mailcow')" "1" "the repair must restart rspamd"
mock_clear_calls
run_allowlist --check
assert_status 0 "a clean check must exit zero"
assert_contains "$LAST_OUTPUT" "no drift" "the clean check must say so"

begin "--dry-run shows the change and writes nothing"
before=$(sha256sum "$CIDR" | awk '{print $1}')
mock_clear_calls
run_allowlist --ip 192.0.2.9 --dry-run
assert_status 0 "the dry run must succeed"
assert_contains "$LAST_OUTPUT" "dry run" "the dry run must be announced"
assert_eq "$(sha256sum "$CIDR" | awk '{print $1}')" "$before" "the whitelist must not change"
assert_eq "$(mock_calls_count 'restart rspamd-mailcow')" "0" "the dry run must not restart rspamd"
assert_eq "$(mock_calls_count 'postfix reload')" "0" "the dry run must not reload Postfix"

begin "an existing whitelist entry is preserved"
printf '# admin entry\n203.0.113.7/32\tpermit\n' >"$CIDR"
run_allowlist --ip 188.245.221.122
assert_status 0 "the run must succeed"
assert_contains "$(cat "$CIDR")" "203.0.113.7/32" "the admin entry must survive"
assert_eq "$(grep -c '^188\.245\.221\.122/32[[:space:]]*permit$' "$CIDR")" "1" \
    "the managed entry must be present"

begin "multiple addresses are deduplicated and normalised"
run_allowlist --ip 192.0.2.1 --ip 192.0.2.1/32 --ip 2001:db8::25
assert_status 0 "the run must succeed"
assert_contains "$(cat "$CIDR")" "192.0.2.1/32" "the IPv4 network must be written"
assert_contains "$(cat "$CIDR")" "2001:db8::25/128" "the bare IPv6 address must gain /128"
assert_eq "$(grep -c '^192\.0\.2\.1/32[[:space:]]*permit$' "$CIDR")" "1" \
    "duplicates must collapse"
assert_eq "$(grep -c '^203\.0\.113\.7/32[[:space:]]*permit$' "$CIDR")" "1" \
    "the admin entry must still be there"

begin "--remove restores the previous configuration"
mock_clear_calls
run_allowlist --remove
assert_status 0 "the removal must succeed"
assert_not_contains "$(cat "$CIDR")" "188.245.221.122" "the managed entry must be gone"
assert_contains "$(cat "$CIDR")" "203.0.113.7/32" "the admin entry must remain"
assert_eq "$(cat "$SETTINGS")" "" "the settings file must be empty"
assert_no_file "$MXB_ALLOWLIST_STATE" "the saved list must be gone"
assert_eq "$(mock_calls_count 'restart rspamd-mailcow')" "1" "rspamd must restart"
assert_eq "$(mock_calls_count 'postfix reload')" "1" "Postfix must reload"
run_allowlist --check
assert_status 0 "nothing is left to check"
assert_contains "$LAST_OUTPUT" "nothing to check" "the empty state must be explained"
run_allowlist --remove
assert_status 0 "removing again must be harmless"
assert_contains "$LAST_OUTPUT" "nothing to remove" "the second removal must be a no-op"

begin "the rspamd block alone can recover the address list"
fresh_sandbox
run_allowlist --ip 192.0.2.50
assert_status 0 "the first run must succeed"
rm -f "$MXB_ALLOWLIST_STATE" "$CIDR"
run_allowlist --no-reload
assert_status 0 "the address must be recovered from the rspamd block"
assert_contains "$(cat "$CIDR")" "192.0.2.50/32" "the postscreen entry must be recreated"
assert_file "$MXB_ALLOWLIST_STATE" "the saved list must be recreated"

begin "an invalid address is refused before any change"
fresh_sandbox
run_allowlist --ip 999.1.1.1
assert_status 1 "an invalid address must abort"
assert_contains "$LAST_OUTPUT" "not a valid IP address" "the error must be explicit"
assert_no_file "$CIDR" "nothing may be written"
run_allowlist --ip not-an-address
assert_status 1 "a non-address must abort"
assert_no_file "$CIDR" "nothing may be written"

begin "a changed Mailcow postscreen configuration is refused, not edited"
fresh_sandbox
export MOCK_POSTSCREEN_ACCESS="permit_mynetworks, cidr:/opt/postfix/conf/postscreen_access.cidr"
run_allowlist --ip 198.51.100.4
assert_status 1 "an unexpected postscreen layout must abort"
assert_contains "$LAST_OUTPUT" "does not reference custom_postscreen_whitelist.cidr" \
    "the reason must be named"
assert_no_file "$CIDR" "no unfamiliar file may be created"
export MOCK_POSTSCREEN_ACCESS=""

begin "an invalid rspamd configuration is rolled back"
fresh_sandbox
printf 'admin_rule {\n  priority = low;\n}\n' >"$SETTINGS"
export MOCK_RSPAMD_CONFIGTEST_FAIL=1
run_allowlist --ip 198.51.100.5
assert_status 1 "invalid rspamd configuration must abort"
assert_contains "$LAST_OUTPUT" "rolling back" "the rollback must be announced"
assert_contains "$(cat "$SETTINGS")" "admin_rule" "the previous settings must be restored"
assert_no_file "$CIDR" "the created whitelist must be removed again"
assert_no_file "$MXB_ALLOWLIST_STATE" "no address list may be saved"
export MOCK_RSPAMD_CONFIGTEST_FAIL=0

begin "a failed rspamd restart is rolled back"
fresh_sandbox
export MOCK_RSPAMD_RESTART_FAIL=1
run_allowlist --ip 198.51.100.6
assert_status 1 "a failed restart must abort"
assert_contains "$LAST_OUTPUT" "failed to restart" "the failure must be explained"
assert_contains "$LAST_OUTPUT" "rolling back" "the rollback must be announced"
assert_no_file "$CIDR" "the created whitelist must be removed again"
assert_no_file "$SETTINGS" "the created rspamd settings must be removed again"
assert_no_file "$MXB_ALLOWLIST_STATE" "no address list may be saved"
export MOCK_RSPAMD_RESTART_FAIL=0

begin "a failed Postfix reload is rolled back"
fresh_sandbox
export MOCK_RELOAD_FAIL=1
run_allowlist --ip 198.51.100.8
assert_status 1 "a failed reload must abort"
assert_contains "$LAST_OUTPUT" "failed to reload" "the failure must be explained"
assert_contains "$LAST_OUTPUT" "rolling back" "the rollback must be announced"
assert_no_file "$CIDR" "the created whitelist must be removed again"
assert_no_file "$SETTINGS" "the created rspamd settings must be removed again"
assert_no_file "$MXB_ALLOWLIST_STATE" "no address list may be saved"
export MOCK_RELOAD_FAIL=0

begin "--no-reload writes and validates without touching the services"
fresh_sandbox
mock_clear_calls
run_allowlist --ip 198.51.100.7 --no-reload
assert_status 0 "the write-only run must succeed"
assert_contains "$LAST_OUTPUT" "were not reloaded" "the skipped reload must be stated"
assert_eq "$(mock_calls_count 'restart rspamd-mailcow')" "0" "rspamd must not restart"
assert_eq "$(mock_calls_count 'postfix reload')" "0" "Postfix must not reload"
assert_file "$SETTINGS" "the files must still be written"

finish
