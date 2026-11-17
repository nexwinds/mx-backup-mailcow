#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared helpers for the mx-backup-mailcow test suite.
#
# Tests never touch the real system: every path is redirected below a
# temporary directory and every external command used by the scripts is
# replaced by a mock (see tests/lib/mocks.sh).
#
set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)

if [[ -n "${MXB_TEST_TOOLS:-}" ]]; then
    PATH="$MXB_TEST_TOOLS:$PATH"
    export PATH
fi

SYNC="$REPO_ROOT/sync-mailcow.sh"
INSTALL="$REPO_ROOT/install.sh"
UPDATE="$REPO_ROOT/update.sh"
DIAGNOSE="$REPO_ROOT/diagnose.sh"
UPDATE_SCRIPTS="$REPO_ROOT/update-scripts.sh"
BUILDER="$REPO_ROOT/scripts/build-release.sh"

PASS=0
FAIL=0
LAST_OUTPUT=""
LAST_STATUS=0

# shellcheck source=tests/lib/mocks.sh
source "$TESTS_DIR/lib/mocks.sh"

is_windows() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
        *) return 1 ;;
    esac
}

begin() {
    printf '\n  [test] %s\n' "$1"
}

pass() { PASS=$((PASS + 1)); }

failtest() {
    FAIL=$((FAIL + 1))
    printf '    FAIL: %s\n' "$*" >&2
}

finish() {
    printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
    [[ "$FAIL" -eq 0 ]]
}

assert_eq() {
    if [[ "$1" == "$2" ]]; then pass; else failtest "$3 (expected '$1', got '$2')"; fi
}

assert_ne() {
    if [[ "$1" != "$2" ]]; then pass; else failtest "$3 (values are equal: '$1')"; fi
}

assert_contains() {
    if [[ "$1" == *"$2"* ]]; then pass; else failtest "$3 (missing '$2')"; fi
}

assert_not_contains() {
    if [[ "$1" != *"$2"* ]]; then pass; else failtest "$3 (unexpected '$2')"; fi
}

assert_file() {
    if [[ -f "$1" ]]; then pass; else failtest "$2 (missing file $1)"; fi
}

assert_no_file() {
    if [[ ! -e "$1" ]]; then pass; else failtest "$2 (unexpected path $1)"; fi
}

assert_dir() {
    if [[ -d "$1" ]]; then pass; else failtest "$2 (missing directory $1)"; fi
}

assert_status() {
    if [[ "$LAST_STATUS" -eq "$1" ]]; then pass; else failtest "$2 (expected exit $1, got $LAST_STATUS)"; fi
}

assert_mode() {
    local file=$1 mode=$2 msg=$3 actual
    if is_windows; then
        pass
        return 0
    fi
    actual=$(stat -c '%a' "$file" 2>/dev/null || printf '?')
    if [[ "$actual" == "$mode" ]]; then pass; else failtest "$msg (expected mode $mode, got $actual)"; fi
}

run() {
    LAST_OUTPUT=$("$@" 2>&1)
    LAST_STATUS=$?
    return 0
}

# shellcheck disable=SC2034  # LAST_OUTPUT is consumed by the test files
run_with_stdin() {
    local input=$1
    shift
    LAST_OUTPUT=$(printf '%s\n' "$input" | "$@" 2>&1)
    LAST_STATUS=$?
    return 0
}

assert_file_lines() {
    local file=$1 msg=$2 actual expected
    shift 2
    expected=$(printf '%s\n' "$@" | sort)
    actual=$(sort "$file" 2>/dev/null)
    if [[ "$actual" == "$expected" ]]; then
        pass
    else
        failtest "$msg"
        printf '      expected:\n%s\n      actual:\n%s\n' "$expected" "$actual" >&2
    fi
}

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------
sandbox_init() {
    TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/mxb-test.XXXXXX")
    export TEST_TMP

    export MXB_SKIP_ROOT_CHECK=1
    export MXB_SKIP_AUTO_TLS=1
    export MXB_ETC="$TEST_TMP/etc"
    export MXB_CONFIG_FILE="$TEST_TMP/etc/config"
    export MXB_MAPS_DIR="$TEST_TMP/postfix"
    export MXB_STATE_DIR="$TEST_TMP/state"
    export MXB_LOG_DIR="$TEST_TMP/log"
    export MXB_BACKUP_DIR="$TEST_TMP/backups"
    export MXB_INSTALL_DIR="$TEST_TMP/opt"
    export MXB_BIN_DIR="$TEST_TMP/bin"
    export MXB_OS_RELEASE="$TEST_TMP/os-release"
    export MXB_REBOOT_MARKER="$TEST_TMP/reboot-required"
    export MXB_REBOOT_PKGS="$TEST_TMP/reboot-required.pkgs"
    export MXB_SYSTEMD_DIR="$TEST_TMP/systemd"
    export MXB_LOGROTATE_DIR="$TEST_TMP/logrotate"
    export MXB_POSTFIX_ETC="$TEST_TMP/postfix-etc"
    export MXB_POSTFIX_TEMPLATE_DIR="$TEST_TMP/postfix-templates"
    export MXB_SSH_DIR="$TEST_TMP/ssh"
    export MXB_CA_BUNDLE="$TEST_TMP/ca-certificates.crt"
    export MXB_LETSENCRYPT_DIR="$TEST_TMP/letsencrypt"
    export MXB_RENEWAL_HOOK_DIR="$TEST_TMP/letsencrypt/renewal-hooks/deploy"
    export MAILCOW_DIR="$TEST_TMP/mailcow"
    export MXB_ALLOWLIST_STATE="$TEST_TMP/mailcow-allowlist.conf"
    export MXB_ALLOWLIST_BACKUP_DIR="$TEST_TMP/allowlist-backups"

    export MOCK_DIR="$TEST_TMP/mock"
    export MOCK_FIXTURES="$TEST_TMP/fixtures"
    export MOCK_RELEASE_DIR="$TEST_TMP/release"
    export MOCK_JOURNAL="$TEST_TMP/journal.log"
    export MOCK_FQDN="mx2.example.com"

    mkdir -p "$MXB_ETC" "$MXB_MAPS_DIR" "$MXB_STATE_DIR" "$MXB_LOG_DIR" \
        "$MXB_BACKUP_DIR" "$MOCK_DIR" "$MOCK_FIXTURES" "$MXB_BIN_DIR" "$TEST_TMP/bin" \
        "$MXB_SYSTEMD_DIR" "$MXB_LOGROTATE_DIR" "$MXB_POSTFIX_ETC" \
        "$MXB_POSTFIX_TEMPLATE_DIR" "$MXB_SSH_DIR"
    mkdir -p "$MAILCOW_DIR/data/conf/postfix" "$MAILCOW_DIR/data/conf/rspamd/local.d"
    : >"$MAILCOW_DIR/docker-compose.yml"
    printf 'Port 22\n' >"$MXB_SSH_DIR/sshd_config"
    cat >"$MXB_POSTFIX_TEMPLATE_DIR/main.cf.debian" <<'EOF'
# Postfix package template (test fixture)
smtpd_banner = $myhostname ESMTP $mail_name (Ubuntu)
compatibility_level = 3.6
EOF
    cat >"$MXB_POSTFIX_TEMPLATE_DIR/master.cf.dist" <<'EOF'
smtp      inet  n       -       y       -       -       smtpd
pickup    unix  n       -       y       60      1       pickup
EOF
    printf -- '-----BEGIN CERTIFICATE-----\nMIIBtest\n-----END CERTIFICATE-----\n' >"$MXB_CA_BUNDLE"
    printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n' >"$MXB_OS_RELEASE"
    : >"$MOCK_JOURNAL"
    write_config
    use_fixtures full
    mock_reset
}

sandbox_destroy() {
    [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]] && rm -rf -- "$TEST_TMP"
}

reset_runtime() {
    rm -rf "$MXB_STATE_DIR" "$MXB_LOG_DIR" "$MXB_MAPS_DIR"
    mkdir -p "$MXB_STATE_DIR" "$MXB_LOG_DIR" "$MXB_MAPS_DIR"
}

write_config() {
    cat >"$MXB_CONFIG_FILE" <<'EOF'
BACKUP_MX_HOSTNAME="mx2.example.com"
MAILCOW_HOST="mail.example.com"
MAILCOW_API_KEY="0123456789abcdef0123456789abcdef"
MAILCOW_API_CA_FILE=""
MAILCOW_PRIMARY_IP="203.0.113.10"
MAILCOW_PRIMARY_PORT=25
SMTP_TLS_MODE="secure"
SMTP_TLS_MATCH_HOSTNAME="mail.example.com"
SMTPD_TLS_CERT_FILE=""
SMTPD_TLS_KEY_FILE=""
OPERATIONAL_MAIL_TO=""
EXCLUDE_DOMAINS=""
RELAX_AFTER_DAYS=7
QUEUE_LIFETIME="7d"
MESSAGE_SIZE_LIMIT="104857600"
EOF
    chmod 600 "$MXB_CONFIG_FILE" 2>/dev/null || true
}

use_fixtures() {
    local name=$1 file
    rm -f "$MOCK_FIXTURES"/*.json 2>/dev/null || true
    for file in "$TESTS_DIR/fixtures/$name"/*.json; do
        [[ -f "$file" ]] && cp "$file" "$MOCK_FIXTURES/"
    done
}

seed_postconf() {
    mock_reset_postconf
}

seed_empty_maps() {
    local name
    for name in relay_domains relay_recipients transport smtp_tls_policy aliases; do
        : >"$MXB_MAPS_DIR/$name"
        : >"$MXB_MAPS_DIR/$name.db"
    done
}

seed_map_content() {
    local domain=$1
    printf '%s\tOK\n' "$domain" >"$MXB_MAPS_DIR/relay_domains"
    printf '%s\tsmtp:[203.0.113.10]:25\n' "$domain" >"$MXB_MAPS_DIR/transport"
    printf 'old@%s\tOK\n' "$domain" >"$MXB_MAPS_DIR/relay_recipients"
    printf '[203.0.113.10]:25\tmay\n' >"$MXB_MAPS_DIR/smtp_tls_policy"
    local name
    for name in relay_domains relay_recipients transport smtp_tls_policy; do
        cp "$MXB_MAPS_DIR/$name" "$MXB_MAPS_DIR/$name.db"
    done
}

sync_once() {
    run bash "$SYNC" "$@"
}

installed_app_fixture() {
    local version=${1:-1.0.0}
    mkdir -p "$MXB_INSTALL_DIR/bin" "$MXB_INSTALL_DIR/systemd"
    cp "$SYNC" "$UPDATE" "$DIAGNOSE" "$UPDATE_SCRIPTS" "$INSTALL" "$MXB_INSTALL_DIR/bin/"
    chmod +x "$MXB_INSTALL_DIR/bin/"*.sh
    cp "$REPO_ROOT/systemd/"* "$MXB_INSTALL_DIR/systemd/"
    printf '%s\n' "$version" >"$MXB_INSTALL_DIR/VERSION"
    (
        cd "$MXB_INSTALL_DIR" || exit 1
        find bin -type f -name '*.sh' -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
    )
}

prepare_release() {
    local version=$1 out
    out="$MOCK_RELEASE_DIR-$version"
    rm -rf "$out"
    bash "$BUILDER" --source "$REPO_ROOT" --out "$out" --version "$version" >/dev/null 2>&1
    printf '%s' "$out"
}

prepare_broken_release() {
    local version=$1 out src
    out="$MOCK_RELEASE_DIR-$version"
    src="$TEST_TMP/broken-src-$version"
    rm -rf "$out" "$src"
    cp -a "$REPO_ROOT" "$src"
    printf '\nif then\n' >>"$src/sync-mailcow.sh"
    bash "$BUILDER" --source "$src" --out "$out" --version "$version" >/dev/null 2>&1
    rm -rf "$src"
    printf '%s' "$out"
}

json_get() {
    jq -r "$2" "$1" 2>/dev/null | tr -d '\r'
}

write_state_fixture() {
    local mailboxes=${1:-100} domains=${2:-10} recipients=${3:-200} epoch=${4:-$(date +%s)}
    mkdir -p "$MXB_STATE_DIR/state"
    jq -n \
        --argjson mailboxes "$mailboxes" \
        --argjson domains "$domains" \
        --argjson recipients "$recipients" \
        --argjson epoch "$epoch" \
        '{
            schema_version: 1,
            status: "ok",
            source: "api",
            last_api_success_epoch: $epoch,
            relaxed: false,
            counts: {
                domains: $domains,
                mailboxes: $mailboxes,
                aliases: 0,
                alias_domains: 0,
                recipients: $recipients,
                wildcards: 0
            }
        }' >"$MXB_STATE_DIR/state/sync-state.json"
}

set_state_epoch() {
    local epoch=$1 file="$MXB_STATE_DIR/state/sync-state.json"
    jq --argjson e "$epoch" '.last_api_success_epoch = $e' "$file" >"$file.tmp" && mv "$file.tmp" "$file"
}
