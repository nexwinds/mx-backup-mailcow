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
assert_contains "$LAST_OUTPUT" "Clock synchronization state" "clock state is reported"
assert_contains "$LAST_OUTPUT" "Inbound TLS (port 25)" "inbound TLS state is reported"
assert_contains "$LAST_OUTPUT" "starttls: not configured" "missing inbound TLS is stated explicitly"
assert_contains "$LAST_OUTPUT" "Postfix chroot and map visibility" "chroot visibility is reported"
assert_contains "$LAST_OUTPUT" "smtpd cannot read" "the chroot consequence is explained"
assert_contains "$LAST_OUTPUT" "Local recipient acceptance (RCPT probe)" "the RCPT probe is reported"
assert_contains "$LAST_OUTPUT" "probe unavailable" "an unusable probe is stated, not hidden"
assert_contains "$LAST_OUTPUT" "Forward-hop TLS verification" "forward-hop TLS is reported"
assert_contains "$LAST_OUTPUT" "policy mode: secure" "the forwarding policy mode is reported"
assert_contains "$LAST_OUTPUT" "Delivery evidence" "delivery evidence is reported"
assert_contains "$LAST_OUTPUT" "Map consistency" "map consistency is reported"
assert_contains "$LAST_OUTPUT" "domains without a transport entry (would loop to this host): none" \
    "transport coverage is verified"
assert_contains "$LAST_OUTPUT" "smtp_tls_policy: [203.0.113.10]:25 secure match=mail.example.com" \
    "the effective TLS policy is reported verbatim"
assert_contains "$LAST_OUTPUT" "tls_verify: ok" \
    "the API TLS result is interpreted instead of printed as a bare number"

begin "a failed API connection is not reported as verified TLS"
export MOCK_CURL_FAIL=1
run bash "$DIAGNOSE" --stdout --lines 20
assert_status 0 "diagnose should succeed even when curl fails"
assert_contains "$LAST_OUTPUT" "tls_verify: unknown (curl exited" \
    "a connection failure must not be called verified TLS"
assert_not_contains "$LAST_OUTPUT" "tls_verify: ok" \
    "no TLS response means the chain was not verified"
export MOCK_CURL_FAIL=0

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

begin "the terminal summary answers whether the server works"
mock_set_unit_state postfix active
mock_set_unit_state mailcow-sync.timer active
postconf -e 'smtpd_tls_cert_file=/etc/ssl/mail/cert.pem'
postconf -e 'smtpd_tls_key_file=/etc/ssl/mail/key.pem'
run bash "$DIAGNOSE" --lines 20
assert_status 0 "summary run should succeed"
assert_contains "$LAST_OUTPUT" "Health summary (version" "the summary must be printed"
assert_contains "$LAST_OUTPUT" "Host:" "host is summarised"
assert_contains "$LAST_OUTPUT" "Postfix:" "Postfix state is summarised"
assert_contains "$LAST_OUTPUT" "Sync timer:" "timer state is summarised"
assert_contains "$LAST_OUTPUT" "Last sync:" "last synchronization is summarised"
assert_contains "$LAST_OUTPUT" "ok via api" "the successful API source is summarised"
assert_contains "$LAST_OUTPUT" "Inbound STARTTLS:" "inbound TLS is summarised"
assert_contains "$LAST_OUTPUT" "Outbound SMTP TLS:" "outbound TLS is summarised"
assert_contains "$LAST_OUTPUT" "secure (verified as" "outbound TLS verification is summarised"
assert_contains "$LAST_OUTPUT" "healthy - no obvious problems detected" "a healthy server must get a plain verdict"
assert_not_contains "$LAST_OUTPUT" "Attention:" "a healthy server has no attention list"
summary_report=$(printf '%s\n' "$LAST_OUTPUT" | tail -n 1)
assert_file "$summary_report" "the report path stays the last line"

begin "the summary flags a degraded sync and a stale API"
set_state_epoch "$(( $(date +%s) - 18000 ))"
jq '.status = "degraded" | .source = "cache"' "$MXB_STATE_DIR/state/sync-state.json" \
    >"$MXB_STATE_DIR/state/sync-state.json.tmp"
mv "$MXB_STATE_DIR/state/sync-state.json.tmp" "$MXB_STATE_DIR/state/sync-state.json"
run bash "$DIAGNOSE" --lines 20
assert_status 0 "degraded summary run should succeed"
assert_contains "$LAST_OUTPUT" "Assessment:           needs attention" "a degraded sync must be flagged"
assert_contains "$LAST_OUTPUT" "the maps come from cache" "the cache fallback must be explained"
assert_contains "$LAST_OUTPUT" "over 4 hours old" "a stale API success must be flagged"

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
assert_contains "$LAST_OUTPUT" "Health summary" "the terminal receives the summary"
assert_eq "$(printf '%s\n' "$LAST_OUTPUT" | tail -n 1)" "$report" "the report path must be the last line"

begin "--stdout keeps the report stream clean"
bash "$DIAGNOSE" --stdout --lines 10 >"$TEST_TMP/stdout.out" 2>"$TEST_TMP/stderr.out"
assert_status 0 "the stdout mode should succeed"
assert_contains "$(cat "$TEST_TMP/stdout.out")" "## AI analysis prompt" "the report stays on stdout"
assert_not_contains "$(cat "$TEST_TMP/stdout.out")" "Health summary" "the summary must not pollute the report"
assert_contains "$(cat "$TEST_TMP/stderr.out")" "Health summary" "the summary is still shown on stderr"

begin "unit name masking is limited to address-like names"
assert_contains "$(cat "$report")" "postfix@-.service" "the postfix@- unit name must not be masked"
assert_not_contains "$(cat "$report")" "p***@-.service" "the postfix@- unit name must not look like an address"
assert_contains "$(cat "$report")" "g***@tty1.service" "alphanumeric unit instances are still masked"
assert_not_contains "$(cat "$report")" "getty@tty1.service" "alphanumeric unit instances must not leak in full"

finish
