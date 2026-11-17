#!/usr/bin/env bash
# Postfix provisioning: identity, inbound TLS, chroot visibility, aliases,
# secure forwarding policy, clock and SMTP self-test.
set -uo pipefail
source "$(dirname "$0")/lib/helpers.sh"

sandbox_init
trap sandbox_destroy EXIT

install_local() {
    run bash "$INSTALL" \
        --non-interactive --skip-upgrade --no-firewall --local-dir "$REPO_ROOT" \
        --mailcow-host mail.example.com --primary-ip 203.0.113.10 "$@"
}

install_interactive() {
    local input
    input=$(printf '%s\n' \
        '' \
        'mail.example.com' \
        '203.0.113.10' \
        '0123456789abcdef0123456789abcdef' \
        '' '' \
        'secure' \
        'y')
    run_with_stdin "$input" bash "$INSTALL" \
        --skip-upgrade --no-firewall --local-dir "$REPO_ROOT"
}

map_value() {
    awk -F' = ' -v k="$1" '$1 == k { sub(/^[^=]*= */, ""); print; exit }' \
        "$MOCK_DIR/postconf.state"
}

make_cert_material() {
    printf -- '-----BEGIN CERTIFICATE-----\nMIIBtestCert\n-----END CERTIFICATE-----\n' >"$TEST_TMP/inbound.crt"
    printf -- '-----BEGIN PRIVATE KEY-----\nMIIBtestKey\n-----END PRIVATE KEY-----\n' >"$TEST_TMP/inbound.key"
}

begin "a single-label hostname is refused before any change"
rm -f "$MXB_CONFIG_FILE"
MOCK_FQDN=mxbk
export MOCK_FQDN
install_local
assert_status 1 "a non-FQDN hostname must abort the installation"
assert_contains "$LAST_OUTPUT" "not a fully qualified domain name" "the error must name the root cause"
assert_contains "$LAST_OUTPUT" "hostnamectl set-hostname" "the error must be actionable"
assert_no_file "$MXB_INSTALL_DIR/bin/sync-mailcow.sh" "nothing may be installed"
MOCK_FQDN=mx2.example.com
export MOCK_FQDN

begin "--hostname overrides a single-label system hostname"
sandbox_destroy
sandbox_init
MOCK_FQDN=mxbk
export MOCK_FQDN
install_local --hostname mx2.example.com
assert_status 0 "an explicit FQDN must be accepted"
assert_contains "$(map_value myhostname)" "mx2.example.com" "Postfix must use the override"
MOCK_FQDN=mx2.example.com
export MOCK_FQDN

begin "a persisted FQDN survives a re-run on a single-label system"
sandbox_destroy
sandbox_init
MOCK_FQDN=mxbk
export MOCK_FQDN
install_local --hostname mx2.example.com
assert_status 0 "the first install should succeed"
install_local
assert_status 0 "a re-run without --hostname must use the persisted FQDN"
assert_contains "$(map_value myhostname)" "mx2.example.com" "Postfix must keep the saved identity"
MOCK_FQDN=mx2.example.com
export MOCK_FQDN

begin "a fresh interactive install derives the TLS name from the prompted host"
sandbox_destroy
sandbox_init
rm -f "$MXB_CONFIG_FILE"
install_interactive
assert_status 0 "the interactive install must succeed with the default secure mode"
assert_not_contains "$LAST_OUTPUT" "Inbound TLS certificate chain" \
    "certificate paths must not be prompted for in the default flow"
assert_contains "$(cat "$MXB_CONFIG_FILE")" 'SMTP_TLS_MATCH_HOSTNAME=mail.example.com' \
    "the prompted host must become the certificate name"
assert_contains "$(cat "$MXB_LOG_DIR/install.log")" "primary SMTP TLS verified for mail.example.com" \
    "the default must be verified against the prompted host"

begin "an unsynchronized clock refuses to install"
sandbox_destroy
sandbox_init
export MOCK_NTPSYNC=no
export MXB_CLOCK_WAIT_SECONDS=0
install_local
assert_status 1 "an unsynchronized clock must abort the installation"
assert_contains "$LAST_OUTPUT" "clock is not synchronized" "the error must name the clock"
assert_no_file "$MXB_INSTALL_DIR/bin/sync-mailcow.sh" "nothing may be installed"
export MOCK_NTPSYNC=yes
unset MXB_CLOCK_WAIT_SECONDS

begin "the default forwarding policy is authenticated TLS"
sandbox_destroy
sandbox_init
install_local
assert_status 0 "the installation should succeed"
assert_contains "$(cat "$MXB_MAPS_DIR/smtp_tls_policy")" "secure match=mail.example.com" \
    "the default policy must verify the primary certificate"
assert_contains "$(cat "$MXB_CONFIG_FILE")" 'SMTP_TLS_MODE=secure' "secure mode must be persisted"
assert_contains "$(cat "$MXB_LOG_DIR/install.log")" "primary SMTP TLS verified" "verification must be logged"
assert_contains "$LAST_OUTPUT" "MXB_SKIP_AUTO_TLS=1" \
    "the summary must explain why automatic inbound TLS was skipped"

begin "an unverifiable primary certificate aborts a secure install"
sandbox_destroy
sandbox_init
export MOCK_TLS_FAIL=1
install_local
assert_status 1 "an unverifiable certificate must abort the installation"
assert_contains "$LAST_OUTPUT" "would be deferred" "the error must explain the consequence"
assert_contains "$LAST_OUTPUT" "--smtp-tls-mode may" "the error must name the explicit override"
assert_eq "$(cat "$MXB_MAPS_DIR/smtp_tls_policy" 2>/dev/null)" "" "no policy may be published"
export MOCK_TLS_FAIL=0

begin "may mode is explicit and warns about unauthenticated TLS"
sandbox_destroy
sandbox_init
export MOCK_TLS_FAIL=1
install_local --smtp-tls-mode may
assert_status 0 "may mode must install despite the certificate"
assert_contains "$(cat "$MXB_MAPS_DIR/smtp_tls_policy")" "may" "the policy must be opportunistic"
assert_contains "$(cat "$MXB_LOG_DIR/install.log")" "opportunistic and unauthenticated" \
    "the unverified hop must be logged"
export MOCK_TLS_FAIL=0

begin "aliases are indexed with postalias, not postmap"
sandbox_destroy
sandbox_init
install_local
assert_status 0 "the installation should succeed"
assert_eq "$(mock_calls_count "postalias hash:$MXB_MAPS_DIR/aliases")" "1" \
    "the alias file must be indexed with postalias"
assert_contains "$(cat "$MXB_MAPS_DIR/aliases")" "postmaster: /dev/null" \
    "operational mail is discarded by explicit default"
assert_contains "$(cat "$MXB_LOG_DIR/install.log")" "discarded" "the default must be logged"

begin "operational mail can be forwarded to an operator address"
sandbox_destroy
sandbox_init
install_local --operational-mail Ops@Example.NET
assert_status 0 "the installation should succeed"
assert_contains "$(cat "$MXB_MAPS_DIR/aliases")" "root: ops@example.net" "root mail must reach the operator"
assert_contains "$(cat "$MXB_MAPS_DIR/aliases")" "postmaster: ops@example.net" "postmaster mail must reach the operator"
assert_not_contains "$(cat "$MXB_MAPS_DIR/aliases")" "/dev/null" "nothing may be discarded when a target is set"
assert_contains "$(cat "$MXB_CONFIG_FILE")" 'OPERATIONAL_MAIL_TO=ops@example.net' "the target must be persisted"

begin "inbound TLS is staged where the postfix user can read it"
sandbox_destroy
sandbox_init
unset MXB_SKIP_AUTO_TLS
mock_clear_calls
make_cert_material
install_local --inbound-tls-cert "$TEST_TMP/inbound.crt" --inbound-tls-key "$TEST_TMP/inbound.key"
assert_status 0 "the installation should succeed"
assert_eq "$(mock_calls_count 'certbot certonly')" "0" \
    "an explicitly supplied certificate must not trigger a certificate request"
assert_file "$MXB_POSTFIX_ETC/tls/mx2.example.com.crt" "the chain must be staged"
assert_file "$MXB_POSTFIX_ETC/tls/mx2.example.com.key" "the key must be staged"
assert_eq "$(map_value smtpd_tls_cert_file)" "$MXB_POSTFIX_ETC/tls/mx2.example.com.crt" \
    "Postfix must use the staged chain"
assert_eq "$(map_value smtpd_tls_key_file)" "$MXB_POSTFIX_ETC/tls/mx2.example.com.key" \
    "Postfix must use the staged key"
assert_contains "$(cat "$MXB_CONFIG_FILE")" "SMTPD_TLS_CERT_FILE=$TEST_TMP/inbound.crt" \
    "the source of the chain must be persisted"
assert_contains "$(cat "$MXB_LOG_DIR/install.log")" "inbound STARTTLS enabled" "inbound TLS must be logged"

begin "a certbot-managed certificate installs a renewal hook"
sandbox_destroy
sandbox_init
make_cert_material
lesite="$MXB_LETSENCRYPT_DIR/live/mx2.example.com"
mkdir -p "$lesite"
cp "$TEST_TMP/inbound.crt" "$lesite/fullchain.pem"
cp "$TEST_TMP/inbound.key" "$lesite/privkey.pem"
install_local
assert_status 0 "the installation should detect the certbot certificate"
assert_file "$MXB_LETSENCRYPT_DIR/renewal-hooks/deploy/mx-backup-mailcow-tls" \
    "a deploy hook must refresh the Postfix copy on renewal"
assert_contains "$(cat "$MXB_LETSENCRYPT_DIR/renewal-hooks/deploy/mx-backup-mailcow-tls")" \
    "postfix reload" "the hook must reload Postfix"
assert_contains "$(cat "$MXB_LETSENCRYPT_DIR/renewal-hooks/deploy/mx-backup-mailcow-tls")" \
    "$MXB_POSTFIX_ETC/tls/mx2.example.com.key" "the hook must update the staged key"
assert_contains "$(cat "$MXB_LOG_DIR/install.log")" "renewal hook" "the hook must be logged"

begin "a certificate is requested automatically when none exists"
sandbox_destroy
sandbox_init
unset MXB_SKIP_AUTO_TLS
mock_clear_calls
install_local
assert_status 0 "the installation should succeed without a pre-existing certificate"
assert_eq "$(mock_calls_count 'certbot certonly')" "1" \
    "certbot must be asked for a certificate exactly once"
assert_file "$MXB_POSTFIX_ETC/tls/mx2.example.com.crt" "the requested chain must be staged"
assert_file "$MXB_POSTFIX_ETC/tls/mx2.example.com.key" "the requested key must be staged"
assert_eq "$(map_value smtpd_tls_cert_file)" "$MXB_POSTFIX_ETC/tls/mx2.example.com.crt" \
    "Postfix must use the requested certificate"
assert_contains "$(cat "$MXB_CONFIG_FILE")" \
    "SMTPD_TLS_CERT_FILE=$MXB_LETSENCRYPT_DIR/live/mx2.example.com/fullchain.pem" \
    "the requested certificate source must be persisted"
assert_contains "$(cat "$MXB_LOG_DIR/install.log")" "obtained an inbound TLS certificate" \
    "the automatic request must be logged"
assert_contains "$(cat "$MXB_LOG_DIR/install.log")" "inbound STARTTLS enabled" \
    "STARTTLS must be enabled after a successful request"
export MXB_SKIP_AUTO_TLS=1

begin "a managed certificate keeps port 80 open for renewals"
sandbox_destroy
sandbox_init
unset MXB_SKIP_AUTO_TLS
mock_clear_calls
run bash "$INSTALL" \
    --non-interactive --skip-upgrade --skip-initial-sync --local-dir "$REPO_ROOT" \
    --mailcow-host mail.example.com --primary-ip 203.0.113.10
assert_status 0 "the installation should succeed"
assert_eq "$(mock_calls_count 'ufw allow 80/tcp comment ACME HTTP-01 renewal')" "1" \
    "the firewall must allow the renewal challenge port"
assert_contains "$(cat "$MXB_LOG_DIR/install.log")" "HTTP: 80 (ACME renewal)" \
    "the open renewal port must be logged"
export MXB_SKIP_AUTO_TLS=1

begin "a failed automatic certificate request degrades to no STARTTLS"
sandbox_destroy
sandbox_init
unset MXB_SKIP_AUTO_TLS
export MOCK_CERTBOT_FAIL=1
install_local
assert_status 0 "a certificate failure must not abort the installation"
assert_eq "$(map_value smtpd_tls_cert_file)" "" "no certificate parameter may be written"
assert_contains "$(cat "$MXB_LOG_DIR/install.log")" "could not obtain an inbound TLS certificate" \
    "the failure must be logged"
assert_contains "$(cat "$MXB_LOG_DIR/install.log")" "continuing without STARTTLS" \
    "the degraded outcome must be explicit"
assert_contains "$(cat "$MXB_LOG_DIR/install.log")" "MTA-STS or DANE" \
    "the consequence must be reported"
export MOCK_CERTBOT_FAIL=0
export MXB_SKIP_AUTO_TLS=1

begin "an unresolvable hostname skips the automatic certificate request"
sandbox_destroy
sandbox_init
unset MXB_SKIP_AUTO_TLS
export MOCK_DNS_FAIL=1
mock_clear_calls
install_local
assert_status 0 "the installation should still succeed"
assert_eq "$(mock_calls_count 'certbot certonly')" "0" \
    "certbot must not run for a name that does not resolve"
assert_contains "$(cat "$MXB_LOG_DIR/install.log")" "does not resolve" \
    "the DNS reason must be logged"
export MOCK_DNS_FAIL=0
export MXB_SKIP_AUTO_TLS=1

begin "a certificate for another hostname is refused"
sandbox_destroy
sandbox_init
make_cert_material
export MOCK_CERT_HOST_MISMATCH=1
install_local --inbound-tls-cert "$TEST_TMP/inbound.crt" --inbound-tls-key "$TEST_TMP/inbound.key"
assert_status 1 "a certificate for the wrong name must abort"
assert_contains "$LAST_OUTPUT" "does not cover mx2.example.com" "the error must name the missing name"
export MOCK_CERT_HOST_MISMATCH=0

begin "missing inbound TLS is reported, not silently accepted"
sandbox_destroy
sandbox_init
unset MXB_SKIP_AUTO_TLS
mock_clear_calls
install_local --no-inbound-tls
assert_status 0 "the installation should succeed without inbound TLS"
assert_eq "$(mock_calls_count 'certbot certonly')" "0" \
    "--no-inbound-tls must not request a certificate"
assert_contains "$(cat "$MXB_LOG_DIR/install.log")" "MTA-STS or DANE" \
    "the consequence must be logged"
assert_eq "$(map_value smtpd_tls_cert_file)" "" "no certificate parameter may be written"
assert_contains "$LAST_OUTPUT" "Inbound TLS is off (--no-inbound-tls)" \
    "the summary must not promise an automatic request after --no-inbound-tls"
export MXB_SKIP_AUTO_TLS=1

begin "the summary names both TLS opt-outs when both are set"
sandbox_destroy
sandbox_init
install_local --no-inbound-tls --skip-initial-sync
assert_status 0 "the installation should succeed with both opt-outs"
assert_contains "$LAST_OUTPUT" "Inbound TLS is off (--no-inbound-tls and MXB_SKIP_AUTO_TLS=1)" \
    "the summary must explain that re-running requires removing both opt-outs"

begin "--no-inbound-tls also clears a certificate from the configuration"
sandbox_destroy
sandbox_init
make_cert_material
install_local --inbound-tls-cert "$TEST_TMP/inbound.crt" --inbound-tls-key "$TEST_TMP/inbound.key"
assert_status 0 "the first installation should enable inbound TLS"
assert_ne "$(map_value smtpd_tls_cert_file)" "" "the certificate must be configured first"
install_local --no-inbound-tls
assert_status 0 "the second installation should succeed"
assert_eq "$(map_value smtpd_tls_cert_file)" "" "the stale parameter must be removed"
assert_eq "$(map_value smtpd_tls_key_file)" "" "the stale key parameter must be removed"
assert_contains "$(cat "$MXB_CONFIG_FILE")" 'SMTPD_TLS_CERT_FILE=' "the certificate key must remain present"
run bash -c 'source "$1"; [[ -z "${SMTPD_TLS_CERT_FILE:-}" && -z "${SMTPD_TLS_KEY_FILE:-}" ]]' _ "$MXB_CONFIG_FILE"
assert_status 0 "the stored certificate and key must be cleared"

begin "chroot is disabled when the maps are outside the jail"
sandbox_destroy
sandbox_init
install_local
assert_status 0 "the installation should succeed"
assert_contains "$(cat "$MOCK_DIR/chroot.state")" "smtp/inet/chroot=n" "smtpd must not be chrooted"
assert_contains "$(cat "$MOCK_DIR/chroot.state")" "smtp/unix/chroot=n" "the SMTP client must not be chrooted"
assert_contains "$(cat "$MXB_LOG_DIR/install.log")" "disabled chroot" "the change must be logged"

begin "chroot is kept when the maps are visible inside the jail"
sandbox_destroy
sandbox_init
jail="$TEST_TMP/queue$MXB_MAPS_DIR"
mkdir -p "$jail"
: >"$jail/relay_recipients.db"
install_local
assert_status 0 "the installation should succeed"
assert_contains "$(cat "$MOCK_DIR/chroot.state")" "smtp/inet/chroot=y" "smtpd may stay chrooted"
assert_not_contains "$(cat "$MXB_LOG_DIR/install.log")" "disabled chroot" "no change is needed"

begin "unused master.cf mail paths are removed"
assert_eq "$(grep -c '^uucp/unix$' "$MOCK_DIR/master.state" || true)" "0" "the uucp pipe must be removed"
assert_eq "$(grep -c '^lmtp/unix$' "$MOCK_DIR/master.state" || true)" "0" "lmtp must be removed"
assert_eq "$(grep -c '^virtual/unix$' "$MOCK_DIR/master.state" || true)" "0" "virtual must be removed"
assert_eq "$(grep -c '^pickup/unix$' "$MOCK_DIR/master.state" || true)" "1" "pickup must remain"
assert_eq "$(grep -c '^relay/unix$' "$MOCK_DIR/master.state" || true)" "1" "relay must remain"

begin "the SMTP path is self-tested after synchronization"
assert_contains "$(cat "$MXB_LOG_DIR/install.log")" "SMTP self-test" "the self-test must run"

begin "sync refuses a Postfix that does not reference the generated maps"
sandbox_destroy
sandbox_init
awk -F' = ' '$1 != "transport_maps"' "$MOCK_DIR/postconf.state" >"$MOCK_DIR/postconf.state.tmp"
mv "$MOCK_DIR/postconf.state.tmp" "$MOCK_DIR/postconf.state"
sync_once
assert_status 1 "a missing transport_maps reference must abort the sync"
assert_contains "$(cat "$MXB_LOG_DIR/sync.log")" "transport_maps" "the log must name the parameter"

begin "sync rejects a parameter pointing at another generated map"
sandbox_destroy
sandbox_init
awk -F' = ' -v m="$MXB_MAPS_DIR" 'BEGIN { OFS = " = " }
    $1 == "transport_maps" { $2 = "hash:" m "/relay_domains" }
    { print }' "$MOCK_DIR/postconf.state" >"$MOCK_DIR/postconf.state.tmp"
mv "$MOCK_DIR/postconf.state.tmp" "$MOCK_DIR/postconf.state"
sync_once
assert_status 1 "a same-directory but wrong map must abort the sync"
assert_contains "$(cat "$MXB_LOG_DIR/sync.log")" "transport_maps" "the log must name the parameter"
assert_contains "$(cat "$MXB_LOG_DIR/sync.log")" "relay_domains" "the log must name the expected map"

finish
