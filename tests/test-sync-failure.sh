#!/usr/bin/env bash
# Synchronization failures: API errors, suspicious payloads, map protection,
# relaxation after a prolonged outage, and rollback.
set -uo pipefail
source "$(dirname "$0")/lib/helpers.sh"

sandbox_init
trap sandbox_destroy EXIT

begin "API authentication failure leaves maps untouched"
seed_map_content keep.test
MOCK_API_CODE=401
sync_once
assert_status 1 "sync must fail on HTTP 401"
assert_eq "$(cat "$MXB_MAPS_DIR/relay_domains")" "keep.test	OK" "relay_domains must be preserved"
assert_contains "$(cat "$MXB_LOG_DIR/sync.log")" "authentication failed" "log must explain the authentication failure"
assert_not_contains "$(cat "$MXB_LOG_DIR/sync.log")" "0123456789abcdef0123456789abcdef" "the API key must never be logged"

begin "API server failure without cache preserves maps"
MOCK_API_CODE=500
sync_once
assert_status 1 "sync must fail on HTTP 500"
assert_eq "$(cat "$MXB_MAPS_DIR/relay_domains")" "keep.test	OK" "maps must not be replaced"

begin "invalid JSON is rejected"
MOCK_API_CODE=200
MOCK_API_BAD_JSON=1
reset_runtime
sync_once
assert_status 1 "sync must fail on invalid JSON"
assert_contains "$(cat "$MXB_LOG_DIR/sync.log")" "not valid JSON" "log must mention invalid JSON"

begin "cache fallback keeps the mail flow running"
export MOCK_API_BAD_JSON=0
reset_runtime
use_fixtures full
sync_once
assert_status 0 "initial sync"
api_epoch_before=$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.last_api_success_epoch')
MOCK_API_CODE=500
mock_clear_calls
sync_once
assert_status 0 "cache fallback must succeed"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.source')" "cache" "source must be cache"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.status')" "degraded" "status must be degraded"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.last_api_success_epoch')" "$api_epoch_before" "last API success must be preserved"
assert_eq "$(mock_calls_count 'postfix reload')" "0" "unchanged maps must not trigger a reload"

begin "suspicious drop is rejected"
MOCK_API_CODE=200
reset_runtime
use_fixtures full
sync_once
jq '.counts.mailboxes = 100 | .counts.domains = 10 | .counts.recipients = 200' \
    "$MXB_STATE_DIR/state/sync-state.json" >"$TEST_TMP/state.tmp"
mv "$TEST_TMP/state.tmp" "$MXB_STATE_DIR/state/sync-state.json"
use_fixtures small
sync_once
assert_status 1 "a large drop must abort the sync"
assert_contains "$(cat "$MXB_LOG_DIR/sync.log")" "dropped from" "log must explain the suspicious drop"
sync_once --force
assert_status 0 "--force must override the drop protection"

begin "postmap failure leaves maps untouched"
reset_runtime
use_fixtures full
seed_map_content keep.test
MOCK_POSTMAP_FAIL=1
sync_once
assert_status 1 "postmap failure must abort the sync"
assert_eq "$(cat "$MXB_MAPS_DIR/relay_domains")" "keep.test	OK" "maps must be preserved"
export MOCK_POSTMAP_FAIL=0

begin "reload failure restores the previous maps"
seed_map_content keep.test
MOCK_RELOAD_FAIL=1
sync_once
assert_status 1 "reload failure must fail the sync"
assert_eq "$(cat "$MXB_MAPS_DIR/relay_domains")" "keep.test	OK" "previous maps must be restored"
assert_contains "$(cat "$MXB_LOG_DIR/sync.log")" "restoring the previous snapshot" "log must mention the restore"
export MOCK_RELOAD_FAIL=0

begin "rollback restores the last known good maps"
reset_runtime
use_fixtures full
sync_once
good_sum=$(sha256sum "$MXB_MAPS_DIR/relay_recipients" | awk '{print $1}')
use_fixtures small
sync_once
assert_ne "$(sha256sum "$MXB_MAPS_DIR/relay_recipients" | awk '{print $1}')" "$good_sum" "maps should have changed"
sync_once --rollback
assert_status 0 "rollback must succeed"
assert_eq "$(sha256sum "$MXB_MAPS_DIR/relay_recipients" | awk '{print $1}')" "$good_sum" "rollback must restore the previous map"
assert_contains "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.message')" "restored snapshot" "state must record the rollback"

begin "rollback to the oldest retained snapshot is not pruned"
reset_runtime
use_fixtures full
sync_once
rm -rf "$MXB_BACKUP_DIR"/maps-*
target="$MXB_BACKUP_DIR/maps-20200101T000000Z-1"
for stamp in 20200101 20200102 20200103 20200104 20200105; do
    dir="$MXB_BACKUP_DIR/maps-${stamp}T000000Z-1"
    mkdir -p "$dir"
    cp -p "$MXB_MAPS_DIR"/relay_domains "$MXB_MAPS_DIR"/relay_recipients \
        "$MXB_MAPS_DIR"/transport "$MXB_MAPS_DIR"/smtp_tls_policy "$dir/"
    cp -p "$MXB_MAPS_DIR"/relay_domains.db "$MXB_MAPS_DIR"/relay_recipients.db \
        "$MXB_MAPS_DIR"/transport.db "$MXB_MAPS_DIR"/smtp_tls_policy.db "$dir/"
    touch -t "${stamp}0000" "$dir"
done
printf 'oldest.test\tOK\n' >"$target/relay_domains"
printf '%s\tsmtp:[203.0.113.10]:25\n' "oldest.test" >"$target/transport"
: >"$target/relay_recipients"
rm -f "$target"/*.db
sync_once --rollback "$target"
assert_status 0 "rollback to the oldest retained snapshot must succeed"
assert_file "$target/relay_domains" "the rollback target must not be pruned"
assert_contains "$(cat "$MXB_MAPS_DIR/relay_domains")" "oldest.test" "the oldest snapshot must be restored"

begin "relaxed mode after seven days without a successful API sync"
reset_runtime
use_fixtures full
sync_once
set_state_epoch "$(( $(date +%s) - 8 * 86400 ))"
MOCK_API_CODE=500
sync_once
assert_status 0 "relaxed cache sync must succeed"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.relaxed')" "true" "state must flag relaxation"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.status')" "relaxed" "state status must be relaxed"
assert_contains "$(cat "$MXB_MAPS_DIR/relay_recipients")" "@example.com	OK" "all hosted domains must accept every recipient"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.counts.wildcards')" "4" "four wildcard domains expected"

begin "successful sync returns to strict validation"
MOCK_API_CODE=200
sync_once
assert_status 0 "API sync must succeed"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.relaxed')" "false" "relaxation must be lifted"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.counts.wildcards')" "3" "strict wildcard count restored"

begin "relaxation can be disabled"
printf '\nRELAX_AFTER_DAYS=0\n' >>"$MXB_CONFIG_FILE"
set_state_epoch "$(( $(date +%s) - 30 * 86400 ))"
MOCK_API_CODE=500
sync_once
assert_status 0 "cache sync must still succeed"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.relaxed')" "false" "relaxation must stay disabled"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.counts.wildcards')" "3" "strict wildcards kept"

begin "a lock held by a live process is never removed"
reset_runtime
mkdir -p "$MXB_STATE_DIR/run/sync.lock"
sleep 30 &
foreign_pid=$!
printf '%s\n' "$foreign_pid" >"$MXB_STATE_DIR/run/sync.lock/pid"
sync_once
assert_status 1 "sync must refuse to run while locked"
assert_contains "$(cat "$MXB_LOG_DIR/sync.log")" "another synchronization is running" "lock message"
assert_file "$MXB_STATE_DIR/run/sync.lock/pid" "foreign lock must be preserved"
assert_eq "$(find "$MXB_STATE_DIR/run" -maxdepth 1 -type d -name '.lock.*' | wc -l | tr -d ' ')" "0" "no temporary lock may remain"
kill "$foreign_pid" 2>/dev/null || true
wait "$foreign_pid" 2>/dev/null || true
rm -rf "$MXB_STATE_DIR/run/sync.lock"

begin "a lock with a dead pid is reclaimed"
export MOCK_API_CODE=200
reset_runtime
use_fixtures full
mkdir -p "$MXB_STATE_DIR/run/sync.lock"
printf '999999\n' >"$MXB_STATE_DIR/run/sync.lock/pid"
sync_once
assert_status 0 "a stale lock with a dead pid must be reclaimed"
assert_no_file "$MXB_STATE_DIR/run/sync.lock" "the lock must be removed after success"

begin "a lock directory without a pid is reclaimed"
export MOCK_API_CODE=200
reset_runtime
use_fixtures full
mkdir -p "$MXB_STATE_DIR/run/sync.lock"
sync_once
assert_status 0 "a lock directory without a pid must be reclaimed"
assert_no_file "$MXB_STATE_DIR/run/sync.lock" "the lock must be removed after success"

begin "invalid entries abort unless forced"
export MOCK_API_CODE=200
reset_runtime
use_fixtures full
jq '.[0].username = "bad user@example.com"' "$MOCK_FIXTURES/mailboxes.json" >"$TEST_TMP/m.json"
mv "$TEST_TMP/m.json" "$MOCK_FIXTURES/mailboxes.json"
sync_once
assert_status 1 "invalid mailbox must abort"
assert_contains "$(cat "$MXB_LOG_DIR/sync.log")" "invalid entries" "log must mention invalid entries"
sync_once --force
assert_status 0 "--force must skip invalid entries"

finish
