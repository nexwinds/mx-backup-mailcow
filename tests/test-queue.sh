#!/usr/bin/env bash
# Mail queue: accurate reporting and a strict no-mutation guarantee.
set -uo pipefail
source "$(dirname "$0")/lib/helpers.sh"

sandbox_init
trap sandbox_destroy EXIT

begin "diagnose reports deferred mail and deferral reasons"
sync_once
export MOCK_QUEUE_JSONL="$TESTS_DIR/fixtures/queue.jsonl"
run bash "$DIAGNOSE" --stdout --lines 40
assert_status 0 "diagnose should succeed"
assert_contains "$LAST_OUTPUT" '"total": 2' "two queued messages"
assert_contains "$LAST_OUTPUT" '"deferred": 1' "one deferred message"
assert_contains "$LAST_OUTPUT" '"active": 1' "one active message"
assert_contains "$LAST_OUTPUT" '"oldest_arrival": 1767225600' "oldest arrival timestamp"
assert_contains "$LAST_OUTPUT" 'Connection refused' "deferral reason preserved"
assert_contains "$LAST_OUTPUT" 'd***@example.org' "recipients masked"

begin "no component flushes, deletes or inspects queue files"
assert_eq "$(mock_calls_count 'postqueue -f')" "0" "no queue flush"
assert_eq "$(mock_calls_count 'postsuper')" "0" "no queue administration"
assert_eq "$(mock_calls_count 'postfix flush')" "0" "no Postfix flush"
assert_eq "$(mock_calls_count 'postcat')" "0" "no message inspection"

begin "sync, update and updater do not touch the spool"
for script in "$SYNC" "$UPDATE" "$UPDATE_SCRIPTS" "$DIAGNOSE" "$INSTALL"; do
    content=$(cat "$script")
    assert_not_contains "$content" "/var/spool/postfix" "$(basename "$script") must not access the spool"
    assert_not_contains "$content" "postqueue -f" "$(basename "$script") must not flush the queue"
    assert_not_contains "$content" "postsuper -d" "$(basename "$script") must not delete queue entries"
done

begin "an empty queue is reported cleanly"
export MOCK_QUEUE_JSONL=""
: >"$TEST_TMP/empty-queue.jsonl"
export MOCK_QUEUE_JSONL="$TEST_TMP/empty-queue.jsonl"
run bash "$DIAGNOSE" --stdout --lines 40
assert_status 0 "diagnose should succeed with an empty queue"
assert_contains "$LAST_OUTPUT" "queue is empty" "empty queue reported"

finish
