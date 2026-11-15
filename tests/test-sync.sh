#!/usr/bin/env bash
# Synchronization: map content, counts, idempotency, dry run, empty Mailcow.
set -uo pipefail
source "$(dirname "$0")/lib/helpers.sh"

sandbox_init
trap sandbox_destroy EXIT

begin "initial synchronization from the Mailcow API"
sync_once
assert_status 0 "sync should succeed"
assert_file "$MXB_MAPS_DIR/relay_domains" "relay_domains must exist"
assert_file_lines "$MXB_MAPS_DIR/relay_domains" "relay_domains content" \
    "alias.test	OK" \
    "catchall.test	OK" \
    "example.com	OK" \
    "example.org	OK"
assert_file_lines "$MXB_MAPS_DIR/transport" "transport content" \
    "alias.test	smtp:[203.0.113.10]:25" \
    "catchall.test	smtp:[203.0.113.10]:25" \
    "example.com	smtp:[203.0.113.10]:25" \
    "example.org	smtp:[203.0.113.10]:25"
assert_file_lines "$MXB_MAPS_DIR/relay_recipients" "relay_recipients content" \
    "@alias.test	OK" \
    "@catchall.test	OK" \
    "@example.org	OK" \
    "alice@example.com	OK" \
    "bob@example.com	OK" \
    "erin@example.org	OK" \
    "frank@catchall.test	OK" \
    "info@example.org	OK" \
    "sales@example.com	OK"
assert_file "$MXB_MAPS_DIR/relay_recipients.db" "indexed map must exist"
assert_contains "$(cat "$MXB_MAPS_DIR/smtp_tls_policy")" "203.0.113.10" "TLS policy must reference the primary"

assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.counts.domains')" "4" "domain count"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.counts.mailboxes')" "4" "mailbox count"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.counts.aliases')" "3" "alias count"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.counts.alias_domains')" "1" "alias domain count"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.counts.recipients')" "9" "recipient count"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.counts.wildcards')" "3" "wildcard count"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.status')" "ok" "state status"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.source')" "api" "state source"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.relaxed')" "false" "relaxed flag"
assert_eq "$(mock_calls_count 'postfix reload')" "1" "Postfix must be reloaded once"
assert_eq "$(mock_calls_count 'postfix status')" "1" "Postfix status must be checked once"

begin "cached API data is written"
assert_file "$MXB_STATE_DIR/cache/domains.json" "domain cache"
assert_file "$MXB_STATE_DIR/cache/mailboxes.json" "mailbox cache"
assert_file "$MXB_STATE_DIR/cache/aliases.json" "alias cache"
assert_file "$MXB_STATE_DIR/cache/alias_domains.json" "alias-domain cache"
assert_eq "$(jq 'length' "$MXB_STATE_DIR/cache/domains.json")" "5" "cache keeps all domains"

begin "second run with unchanged data does not reload Postfix"
mock_clear_calls
sync_once
assert_status 0 "second sync should succeed"
assert_eq "$(mock_calls_count 'postfix reload')" "0" "no reload when maps are unchanged"
assert_eq "$(mock_calls_count 'postfix status')" "0" "no status check when maps are unchanged"

begin "dry run changes nothing"
use_fixtures small
mock_clear_calls
map_before=$(sha256sum "$MXB_MAPS_DIR/relay_domains" | awk '{print $1}')
sync_once --dry-run
assert_status 0 "dry run should succeed"
assert_contains "$LAST_OUTPUT" "dry-run" "dry-run summary"
assert_contains "$LAST_OUTPUT" "domains=1" "dry-run reports the new domain count"
assert_eq "$(sha256sum "$MXB_MAPS_DIR/relay_domains" | awk '{print $1}')" "$map_before" "dry run must not touch maps"
assert_eq "$(mock_calls_count 'postfix reload')" "0" "dry run must not reload Postfix"

begin "explicitly empty Mailcow produces empty maps"
reset_runtime
use_fixtures empty
sync_once --allow-empty
assert_status 0 "empty Mailcow is accepted with --allow-empty"
assert_eq "$(wc -l <"$MXB_MAPS_DIR/relay_domains" | tr -d ' ')" "0" "no relay domains"
assert_eq "$(json_get "$MXB_STATE_DIR/state/sync-state.json" '.counts.domains')" "0" "zero domains recorded"

begin "empty Mailcow is rejected by default"
reset_runtime
sync_once
assert_status 1 "empty Mailcow must be rejected without --allow-empty"

begin "excluded domains are skipped regardless of case"
reset_runtime
use_fixtures full
printf '\nEXCLUDE_DOMAINS="CatchAll.Test"\n' >>"$MXB_CONFIG_FILE"
sync_once
assert_status 0 "sync with exclusions should succeed"
assert_not_contains "$(cat "$MXB_MAPS_DIR/relay_domains")" "catchall.test" "excluded domain must not be relayed"
assert_not_contains "$(cat "$MXB_MAPS_DIR/relay_recipients")" "frank@catchall.test" "mailboxes of excluded domains must be skipped"

begin "a missing map index is rebuilt"
reset_runtime
use_fixtures full
sync_once
assert_status 0 "initial sync should succeed"
rm -f "$MXB_MAPS_DIR/relay_recipients.db"
mock_clear_calls
sync_once
assert_status 0 "sync with a missing index should succeed"
assert_file "$MXB_MAPS_DIR/relay_recipients.db" "missing index must be rebuilt"
assert_eq "$(mock_calls_count 'postfix reload')" "1" "a rebuilt index must be reloaded"

begin "a stale map index is rebuilt"
reset_runtime
use_fixtures full
sync_once
assert_status 0 "initial sync should succeed"
touch "$MXB_MAPS_DIR/transport"
mock_clear_calls
sync_once
assert_status 0 "sync with a stale index should succeed"
assert_eq "$(mock_calls_count 'postfix reload')" "1" "a stale index must be reloaded"

begin "a corrupt map index is rebuilt"
reset_runtime
use_fixtures full
sync_once
assert_status 0 "initial sync should succeed"
printf 'corrupt\n' >"$MXB_MAPS_DIR/relay_recipients.db"
mock_clear_calls
sync_once
assert_status 0 "sync with a corrupt index should succeed"
assert_eq "$(mock_calls_count 'postfix reload')" "1" "a corrupt index must be reloaded"
assert_not_contains "$(cat "$MXB_MAPS_DIR/relay_recipients.db")" "corrupt" "the corrupt index must be replaced"

begin "punycode domains are synchronized"
reset_runtime
use_fixtures small
jq '. + [{"domain_name":"example.xn--p1ai","active":"1","relay_all_recipients":"0"}]' \
    "$MOCK_FIXTURES/domains.json" >"$TEST_TMP/domains.tmp"
mv "$TEST_TMP/domains.tmp" "$MOCK_FIXTURES/domains.json"
jq '. + [{"username":"user@example.xn--p1ai","active":"1"}]' \
    "$MOCK_FIXTURES/mailboxes.json" >"$TEST_TMP/mailboxes.tmp"
mv "$TEST_TMP/mailboxes.tmp" "$MOCK_FIXTURES/mailboxes.json"
sync_once
assert_status 0 "punycode domains should synchronize"
assert_contains "$(cat "$MXB_MAPS_DIR/relay_domains")" "example.xn--p1ai" "punycode domain must be relayed"
assert_contains "$(cat "$MXB_MAPS_DIR/relay_recipients")" "user@example.xn--p1ai" "punycode recipient must be accepted"

begin "numeric TLDs are still rejected"
reset_runtime
use_fixtures small
jq '. + [{"domain_name":"bad.123","active":"1","relay_all_recipients":"0"}]' \
    "$MOCK_FIXTURES/domains.json" >"$TEST_TMP/domains.tmp"
mv "$TEST_TMP/domains.tmp" "$MOCK_FIXTURES/domains.json"
jq '. + [{"username":"user@bad.123","active":"1"}]' \
    "$MOCK_FIXTURES/mailboxes.json" >"$TEST_TMP/mailboxes.tmp"
mv "$TEST_TMP/mailboxes.tmp" "$MOCK_FIXTURES/mailboxes.json"
sync_once
assert_status 1 "numeric TLD must still be rejected"
assert_contains "$(cat "$MXB_LOG_DIR/sync.log")" "invalid entries" "invalid entries must be reported"

finish
