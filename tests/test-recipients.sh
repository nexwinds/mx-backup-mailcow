#!/usr/bin/env bash
# Recipient validation: unknown recipients rejected, catch-alls, alias domains,
# relay-all domains and plus-addressing accepted.
set -uo pipefail
source "$(dirname "$0")/lib/helpers.sh"
source "$(dirname "$0")/lib/postfix_lookup.sh"

sandbox_init
trap sandbox_destroy EXIT

begin "generate maps from the full fixture"
sync_once
assert_status 0 "sync should succeed"

check() {
    local address=$1 expected=$2
    assert_eq "$(postfix_decision "$MXB_MAPS_DIR" "$address")" "$expected" "$address"
}

check "alice@example.com" accept
check "ALICE@EXAMPLE.COM" accept
check "alice+newsletter@example.com" accept
check "alice+tag+more@example.com" accept
check "unknown@example.com" reject-recipient
check "unknown+tag@example.com" reject-recipient
check "sales@example.com" accept
check "info@example.org" accept
check "random.person@catchall.test" accept
check "anything@alias.test" accept
check "whatever@example.org" accept
check "erin@example.org" accept
check "ghost@external.test" reject-domain
check "dave@inactive.test" reject-domain
check "old@inactive.test" reject-domain
check "user@sub.example.com" reject-domain
check "not-an-address" reject-invalid

begin "wildcard entries are explicit in the map"
assert_eq "$(grep -c '^@' "$MXB_MAPS_DIR/relay_recipients" | tr -d ' ')" "3" "three wildcard recipients"
assert_contains "$(cat "$MXB_MAPS_DIR/relay_recipients")" "@alias.test" "alias domain wildcard"
assert_contains "$(cat "$MXB_MAPS_DIR/relay_recipients")" "@catchall.test" "catch-all wildcard"
assert_contains "$(cat "$MXB_MAPS_DIR/relay_recipients")" "@example.org" "relay-all wildcard"

begin "no relay domain accepts unknown senders by accident"
assert_eq "$(postfix_decision "$MXB_MAPS_DIR" "someone@not-hosted.test")" "reject-domain" "unrelated domain"

finish
