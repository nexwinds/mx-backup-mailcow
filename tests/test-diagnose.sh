#!/usr/bin/env bash
# Diagnostics: AI prompt, sanitization, queue reporting and read-only behaviour.
set -uo pipefail
source "$(dirname "$0")/lib/helpers.sh"

sandbox_init
trap sandbox_destroy EXIT

API_KEY="0123456789abcdef0123456789abcdef"

begin "prepare a server with state, maps, cache and logs"
sync_once
assert_status 0 "sync should succeed"

MOCK_QUEUE_JSONL="$TESTS_DIR/fixtures/queue.jsonl"
export MOCK_QUEUE_JSONL

cat >"$MOCK_JOURNAL" <<EOF
2026-01-01T00:00:00Z mx2 postfix/smtpd[123]: connect from unknown[192.0.2.5]
2026-01-01T00:00:01Z mx2 sync-mailcow: API request with X-API-Key: $API_KEY
2026-01-01T00:00:01Z mx2 sync-mailcow: loaded key $API_KEY
2026-01-01T00:00:02Z mx2 postfix/smtp[124]: ABC123: to=<bob@example.com>, relay=203.0.113.10[203.0.113.10]:25, status=deferred (connect refused)
2026-01-01T00:00:03Z mx2 sshd[125]: Failed password for root from 192.0.2.5
2026-01-01T00:00:04Z mx2 systemd[1]: Failed to start postfix@-.service - Postfix Mail Transport Agent (instance -).
2026-01-01T00:00:05Z mx2 systemd[1]: Failed to start getty@tty1.service - Getty on tty1.
-----BEGIN OPENSSH PRIVATE KEY-----
AAAAB3NzaC1yc2EAAAADAQABAAABgQC7examplePrivateKeyMaterial
-----END OPENSSH PRIVATE KEY-----
EOF
printf 'sync-mailcow: password=super-secret-value\n' >>"$MXB_LOG_DIR/sync.log"
printf '{"password":"another-secret","api_key":"%s"}\n' "$API_KEY" >"$MXB_STATE_DIR/state/extra.json"

mock_clear_calls

begin "generate the report on stdout"
run bash "$DIAGNOSE" --stdout --lines 50
assert_status 0 "diagnose should succeed"
assert_contains "$LAST_OUTPUT" "# Mailcow Backup MX - health report" "report title"
assert_contains "$LAST_OUTPUT" "## AI analysis prompt" "AI prompt present"
assert_contains "$LAST_OUTPUT" "Do not invent facts" "prompt instructs the analyst"
assert_contains "$LAST_OUTPUT" "## 2. Postfix" "Postfix section"
assert_contains "$LAST_OUTPUT" "## 3. Mailcow synchronization" "synchronization section"
assert_contains "$LAST_OUTPUT" "Queue summary" "queue summary present"
assert_contains "$LAST_OUTPUT" "deferred" "queue state reported"
assert_contains "$LAST_OUTPUT" "connect to 203.0.113.10" "deferral reason reported"
assert_contains "$LAST_OUTPUT" "## 6. Application version and updates" "update section"
assert_contains "$LAST_OUTPUT" "mailcow_host: mail.example.com" "configuration summary is in the report stream"
assert_contains "$LAST_OUTPUT" "installed_version:" "installed version is reported"
assert_contains "$LAST_OUTPUT" "notAfter=" "certificate validity is reported"

begin "credentials and private keys are redacted"
assert_not_contains "$LAST_OUTPUT" "$API_KEY" "API key must not appear"
assert_not_contains "$LAST_OUTPUT" "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7examplePrivateKeyMaterial" "private key material must not appear"
assert_not_contains "$LAST_OUTPUT" "super-secret-value" "passwords must not appear"
assert_not_contains "$LAST_OUTPUT" "another-secret" "JSON secrets must not appear"
assert_contains "$LAST_OUTPUT" "[REDACTED_API_KEY]" "redaction marker present"
assert_contains "$LAST_OUTPUT" "[REDACTED PRIVATE KEY BLOCK]" "private key block replaced"

begin "email local parts are masked"
assert_contains "$LAST_OUTPUT" "b***@example.com" "queue recipients are masked"
assert_not_contains "$LAST_OUTPUT" "bob@example.com" "full recipient address must not appear"
assert_not_contains "$LAST_OUTPUT" "alice@example.com" "full sender address must not appear"

begin "recent log sections contain the newest lines"
for i in $(seq 1 40); do
    printf 'old log line %s\n' "$i"
done >"$MXB_LOG_DIR/sync.log"
{
    printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----'
    printf '%s\n' 'AAAAB3NzaC1yc2EAAAADAQABAAABgQC7tailKeyMaterial'
    printf '%s\n' '-----END OPENSSH PRIVATE KEY-----'
    printf '%s\n' 'RECENT-MARKER'
} >>"$MXB_LOG_DIR/sync.log"
run bash "$DIAGNOSE" --stdout --lines 10
assert_status 0 "diagnose with a long log should succeed"
assert_contains "$LAST_OUTPUT" "RECENT-MARKER" "newest log line must be reported"
assert_not_contains "$LAST_OUTPUT" "old log line 1" "oldest log line must not be reported"
assert_contains "$LAST_OUTPUT" "[REDACTED PRIVATE KEY BLOCK]" "private key block in a log file must be redacted"
assert_not_contains "$LAST_OUTPUT" "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7tailKeyMaterial" "key material in a log file must not appear"

begin "diagnose never mutates the server"
for pattern in "postconf -e" "systemctl restart" "systemctl start" "systemctl stop" \
    "systemctl reload" "postfix reload" "postfix flush" "postqueue -f" \
    "apt-get install" "apt-get upgrade" "postsuper" "postcat"; do
    assert_eq "$(mock_calls_count "$pattern")" "0" "must never call: $pattern"
done
assert_contains "$(cat "$MOCK_DIR/calls.log")" "postqueue -j" "queue read through postqueue -j"

begin "report file is created with restrictive permissions"
run bash "$DIAGNOSE" --lines 20
assert_status 0 "file mode should succeed"
report=$(printf '%s\n' "$LAST_OUTPUT" | tail -n 1)
assert_file "$report" "report file created"
assert_mode "$report" "600" "report must be private"
assert_contains "$(cat "$report")" "## AI analysis prompt" "file report contains the prompt"
assert_contains "$(cat "$report")" "mailcow_host: mail.example.com" "configuration summary is written to the report"
assert_contains "$(cat "$report")" "$MXB_CONFIG_FILE" "file permissions are written to the report"
assert_contains "$(cat "$report")" "installed_version:" "installed version is written to the report"
assert_eq "$(printf '%s\n' "$LAST_OUTPUT" | wc -l | tr -d ' ')" "1" "stdout must contain only the report path"

begin "unit name masking is limited to address-like names"
assert_contains "$(cat "$report")" "postfix@-.service" "the postfix@- unit name must not be masked"
assert_not_contains "$(cat "$report")" "p***@-.service" "the postfix@- unit name must not look like an address"
assert_contains "$(cat "$report")" "g***@tty1.service" "alphanumeric unit instances are still masked"
assert_not_contains "$(cat "$report")" "getty@tty1.service" "alphanumeric unit instances must not leak in full"

finish
