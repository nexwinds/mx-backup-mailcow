#!/usr/bin/env bash
#
# sync-mailcow.sh - synchronize Mailcow domains and recipients into Postfix maps
#
# Part of mx-backup-mailcow. Standalone script: no shared libraries.
#
# The script reads Mailcow's read-only REST API over HTTPS, builds
# relay_domains, relay_recipients, transport and smtp_tls_policy maps for
# Postfix, validates them in a staging directory and installs them atomically.
# A failed synchronization never destroys the maps that are currently in use.
#
set -Eeuo pipefail

SCRIPT_NAME="sync-mailcow"
MAX_MAP_BACKUPS=5
API_TIMEOUT=30
PROG_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# ---------------------------------------------------------------------------
# Paths. Every path can be overridden through the environment; the test suite
# uses this, as do administrators who run the script from a staging tree.
# ---------------------------------------------------------------------------
: "${MXB_ETC:=/etc/mailcow-backup-mx}"
: "${MXB_CONFIG_FILE:=$MXB_ETC/config}"
: "${MXB_MAPS_DIR:=/etc/postfix/mailcow-backup-mx}"
: "${MXB_STATE_DIR:=/var/lib/mailcow-backup-mx}"
: "${MXB_LOG_DIR:=/var/log/mailcow-backup-mx}"
: "${MXB_BACKUP_DIR:=/var/backups/mx-backup-mailcow}"
: "${MXB_INSTALL_DIR:=/opt/mx-backup-mailcow}"

MAP_NAMES=(relay_domains relay_recipients transport smtp_tls_policy)
LOG_FILE="$MXB_LOG_DIR/sync.log"
STATE_DIR="$MXB_STATE_DIR/state"
STATE_FILE="$STATE_DIR/sync-state.json"
CACHE_DIR="$MXB_STATE_DIR/cache"
RUN_DIR="$MXB_STATE_DIR/run"
TMP_DIR="$MXB_STATE_DIR/tmp"
LOCK_DIR="$RUN_DIR/sync.lock"

QUIET=0
FORCE=0
DRY_RUN=0
ALLOW_EMPTY=0
NO_RELOAD=0
NO_POSTFIX_CHECK=0
ROLLBACK_TARGET=""

WORK_DIR=""
BUILD_DIR=""
SNAPSHOT_DIR=""
PREV_STATE=""
SOURCE="api"
LOCK_HELD=0
LOCK_TMP=""
DOMAIN_COUNT=0
MAILBOX_COUNT=0
ALIAS_COUNT=0
ALIAS_DOMAIN_COUNT=0
RECIPIENT_COUNT=0
WILDCARD_COUNT=0

VERSION="unknown"
for version_file in "$PROG_DIR/../VERSION" "$PROG_DIR/VERSION" "$MXB_INSTALL_DIR/VERSION"; do
    [[ -r "$version_file" ]] || continue
    VERSION=$(<"$version_file")
    VERSION=${VERSION//[[:space:]]/}
    [[ -n "$VERSION" ]] && break
done
[[ -n "$VERSION" ]] || VERSION="unknown"

RE_DOMAIN='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9]([a-z0-9-]{0,57}[a-z0-9])?)$'
RE_LOCALPART="^[a-z0-9._%+!\$&*=?^{|}~'/-]+\$"

usage() {
    cat <<'EOF'
Usage: sync-mailcow.sh [OPTIONS]

Synchronize Mailcow domains, mailboxes and aliases into Postfix maps.

Options:
  --dry-run            Build and validate maps, print a summary, change nothing
  --force              Continue despite invalid entries or a suspicious drop
  --allow-empty        Accept an empty Mailcow (no hosted domains)
  --no-reload          Do not reload Postfix after installing maps
  --no-postfix-check   Do not verify that Postfix references these maps
  --rollback [STAMP]   Restore the most recent (or the given) map snapshot
  --quiet              Only write to the log file
  -h, --help           Show this help
  -V, --version        Show script version

Exit status: 0 success (including cache fallback), 1 error.
EOF
}

log() {
    local line
    line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [$SCRIPT_NAME] $*"
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
    if [[ "$QUIET" -eq 0 ]]; then
        printf '%s\n' "$line" >&2
    fi
}

warn() { log "WARN: $*"; }
err()  { log "ERROR: $*"; }

die() {
    err "$*"
    exit 1
}

on_error() {
    local rc=$? line=${1:-?}
    trap - ERR
    log "ERROR: unexpected failure at line ${line} (exit ${rc})"
    exit "$rc"
}

cleanup() {
    local rc=$?
    local held=""
    trap - EXIT
    [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]] && rm -rf -- "$BUILD_DIR" 2>/dev/null || true
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf -- "$WORK_DIR" 2>/dev/null || true
    [[ -n "$LOCK_TMP" && -d "$LOCK_TMP" ]] && rm -rf -- "$LOCK_TMP" 2>/dev/null || true
    if [[ "$LOCK_HELD" -eq 1 && -d "$LOCK_DIR" ]]; then
        [[ -r "$LOCK_DIR/pid" ]] && held=$(<"$LOCK_DIR/pid")
        held=${held//[[:space:]]/}
        [[ "$held" == "$$" ]] && rm -rf -- "$LOCK_DIR" 2>/dev/null || true
    fi
    exit "$rc"
}

trap 'on_error $LINENO' ERR
trap cleanup EXIT

require_root() {
    [[ "${MXB_SKIP_ROOT_CHECK:-0}" == "1" ]] && return 0
    [[ "$(id -u)" -eq 0 ]] || die "must be run as root"
}

prepare_dirs() {
    mkdir -p "$MXB_LOG_DIR" "$STATE_DIR" "$CACHE_DIR" "$RUN_DIR" "$TMP_DIR" \
        "$MXB_MAPS_DIR" "$MXB_BACKUP_DIR"
}

acquire_lock() {
    mkdir -p "$RUN_DIR"
    local pid="" attempt=0
    LOCK_TMP="$RUN_DIR/.lock.$$"
    while (( attempt < 3 )); do
        attempt=$((attempt + 1))
        rm -rf -- "$LOCK_TMP"
        mkdir -p "$LOCK_TMP"
        printf '%s\n' "$$" >"$LOCK_TMP/pid"
        if mv -T -- "$LOCK_TMP" "$LOCK_DIR" 2>/dev/null; then
            LOCK_TMP=""
            LOCK_HELD=1
            return 0
        fi
        pid=""
        [[ -r "$LOCK_DIR/pid" ]] && pid=$(<"$LOCK_DIR/pid")
        pid=${pid//[[:space:]]/}
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            rm -rf -- "$LOCK_TMP"
            LOCK_TMP=""
            die "another synchronization is running (pid $pid)"
        fi
        warn "removing stale synchronization lock"
        rm -rf -- "$LOCK_DIR"
    done
    rm -rf -- "$LOCK_TMP"
    LOCK_TMP=""
    die "cannot acquire synchronization lock"
}

load_config() {
    [[ -r "$MXB_CONFIG_FILE" ]] || die "configuration not found: $MXB_CONFIG_FILE (run install.sh first)"

    # shellcheck disable=SC1090
    . "$MXB_CONFIG_FILE"

    : "${MAILCOW_HOST:?}"
    : "${MAILCOW_API_KEY:?}"
    : "${MAILCOW_PRIMARY_IP:?}"
    : "${MAILCOW_PRIMARY_PORT:=25}"
    : "${SMTP_TLS_MODE:=may}"
    : "${SMTP_TLS_MATCH_HOSTNAME:=}"
    : "${EXCLUDE_DOMAINS:=}"
    : "${RELAX_AFTER_DAYS:=7}"
}

is_domain() { [[ $1 =~ $RE_DOMAIN ]]; }

is_ipv4() {
    local o
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    for o in ${1//./ }; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

is_ipv6() { [[ $1 == *:* && $1 =~ ^[0-9a-fA-F:]+$ ]]; }

is_email() {
    local addr=$1 localpart domain
    [[ $addr == *@* ]] || return 1
    localpart=${addr%@*}
    domain=${addr##*@}
    [[ -n $localpart && -n $domain ]] || return 1
    [[ $localpart =~ $RE_LOCALPART ]] || return 1
    is_domain "$domain"
}

validate_config() {
    is_domain "$MAILCOW_HOST" || die "MAILCOW_HOST is not a valid hostname: $MAILCOW_HOST"
    [[ $MAILCOW_HOST != */* ]] || die "MAILCOW_HOST must not contain a scheme or path"
    [[ $MAILCOW_API_KEY =~ ^[A-Za-z0-9-]+$ ]] || die "MAILCOW_API_KEY contains unexpected characters"
    (( ${#MAILCOW_API_KEY} >= 16 )) || die "MAILCOW_API_KEY is too short"
    if ! is_ipv4 "$MAILCOW_PRIMARY_IP" && ! is_ipv6 "$MAILCOW_PRIMARY_IP"; then
        die "MAILCOW_PRIMARY_IP is not a valid IP address: $MAILCOW_PRIMARY_IP"
    fi
    [[ $MAILCOW_PRIMARY_PORT =~ ^[0-9]+$ ]] && (( MAILCOW_PRIMARY_PORT >= 1 && MAILCOW_PRIMARY_PORT <= 65535 )) \
        || die "MAILCOW_PRIMARY_PORT is invalid"
    case "$SMTP_TLS_MODE" in
        may) ;;
        secure)
            is_domain "$SMTP_TLS_MATCH_HOSTNAME" \
                || die "SMTP_TLS_MODE=secure requires SMTP_TLS_MATCH_HOSTNAME to be a hostname"
            ;;
        *) die "SMTP_TLS_MODE must be 'may' or 'secure'" ;;
    esac
    [[ $RELAX_AFTER_DAYS =~ ^[0-9]+$ ]] || die "RELAX_AFTER_DAYS must be an integer"
    if [[ -n "${MAILCOW_API_CA_FILE:-}" ]]; then
        [[ -r $MAILCOW_API_CA_FILE ]] || die "MAILCOW_API_CA_FILE is not readable: $MAILCOW_API_CA_FILE"
    fi
}

postfix_uses_maps() {
    [[ "$NO_POSTFIX_CHECK" -eq 1 ]] && return 0
    command -v postconf >/dev/null 2>&1 || { warn "postconf not found, skipping Postfix map check"; return 0; }
    local value
    value=$(postconf -h relay_recipient_maps 2>/dev/null || true)
    case "$value" in
        *"$MXB_MAPS_DIR/relay_recipients"*) ;;
        *) die "Postfix does not reference $MXB_MAPS_DIR/relay_recipients (run install.sh)" ;;
    esac
    value=$(postconf -h relay_domains 2>/dev/null || true)
    case "$value" in
        *"$MXB_MAPS_DIR/relay_domains"*) ;;
        *) die "Postfix does not reference $MXB_MAPS_DIR/relay_domains (run install.sh)" ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# API access
# ---------------------------------------------------------------------------
api_get() {
    local endpoint=$1 outfile=$2 url code=000 rc=0
    url="https://${MAILCOW_HOST}/api/v1/get/${endpoint}"
    local -a args=(
        --silent --show-error
        --proto '=https'
        --tlsv1.2
        --connect-timeout 10
        --max-time "$API_TIMEOUT"
        --retry 2 --retry-delay 2
        --header 'Accept: application/json'
        --output "$outfile"
        --write-out '%{http_code}'
    )
    if [[ -n "${MAILCOW_API_CA_FILE:-}" ]]; then
        args+=(--cacert "$MAILCOW_API_CA_FILE")
    fi

    # The API key is supplied through a curl config on stdin so that it never
    # appears in the process list or in shell history.
    code=$(printf 'url = "%s"\nheader = "X-API-Key: %s"\n' "$url" "$MAILCOW_API_KEY" \
        | curl "${args[@]}" --config - 2>>"$LOG_FILE") || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        err "API request failed: ${endpoint} (curl exit ${rc}, HTTP ${code:-000})"
        case "$rc" in
            6)     err "cannot resolve $MAILCOW_HOST" ;;
            7)     err "cannot connect to $MAILCOW_HOST:443" ;;
            35|60) err "TLS verification failed; provide the private CA with MAILCOW_API_CA_FILE" ;;
            28)    err "API request timed out after ${API_TIMEOUT}s" ;;
        esac
        return 1
    fi

    case "$code" in
        200) return 0 ;;
        401|403)
            err "API authentication failed (HTTP $code): check the read-only API key and that $MAILCOW_PRIMARY_IP is allowlisted in Mailcow"
            return 1
            ;;
        *)
            err "Mailcow API returned HTTP $code for ${endpoint}"
            return 1
            ;;
    esac
}

fetch_all() {
    local outdir=$1 ok=1
    mkdir -p "$outdir"
    api_get "domain/all" "$outdir/domains.raw.json" || ok=0
    api_get "mailbox/all" "$outdir/mailboxes.raw.json" || ok=0
    api_get "alias/all" "$outdir/aliases.raw.json" || ok=0
    api_get "alias-domain/all" "$outdir/alias_domains.raw.json" || ok=0
    [[ "$ok" -eq 1 ]]
}

normalize_all() {
    local dir=$1
    jq -e '
        def as_array: if type == "array" then .
                      elif type == "object" and length == 0 then []
                      else error("expected a JSON array") end;
        as_array
        | map(select(type == "object"))
        | map({
            domain_name: ((.domain_name // .domain // "") | tostring | ascii_downcase),
            active: (((.active // "0") | tostring) == "1"),
            relay_all_recipients: (((.relay_all_recipients // "0") | tostring) == "1")
          })
    ' "$dir/domains.raw.json" >"$dir/domains.json" || return 1

    jq -e '
        def as_array: if type == "array" then .
                      elif type == "object" and length == 0 then []
                      else error("expected a JSON array") end;
        as_array
        | map(select(type == "object"))
        | map({
            username: ((.username // "") | tostring | ascii_downcase),
            active: (((.active // "0") | tostring) == "1")
          })
    ' "$dir/mailboxes.raw.json" >"$dir/mailboxes.json" || return 1

    jq -e '
        def as_array: if type == "array" then .
                      elif type == "object" and length == 0 then []
                      else error("expected a JSON array") end;
        as_array
        | map(select(type == "object"))
        | map({
            address: ((.address // "") | tostring | ascii_downcase),
            active: (((.active // "0") | tostring) == "1"),
            is_catch_all: (((.is_catch_all // "0") | tostring) == "1")
          })
    ' "$dir/aliases.raw.json" >"$dir/aliases.json" || return 1

    jq -e '
        def as_array: if type == "array" then .
                      elif type == "object" and length == 0 then []
                      else error("expected a JSON array") end;
        as_array
        | map(select(type == "object"))
        | map({
            alias_domain: ((.alias_domain // "") | tostring | ascii_downcase),
            target_domain: ((.target_domain // "") | tostring | ascii_downcase),
            active: (((.active // "0") | tostring) == "1")
          })
    ' "$dir/alias_domains.raw.json" >"$dir/alias_domains.json" || return 1
}

# ---------------------------------------------------------------------------
# Map rendering
# ---------------------------------------------------------------------------
INVALID_COUNT=0
INVALID_SAMPLES=()

record_invalid() {
    INVALID_COUNT=$((INVALID_COUNT + 1))
    if (( ${#INVALID_SAMPLES[@]} < 5 )); then
        INVALID_SAMPLES+=("$1")
    fi
}

render_maps() {
    local dir=$1 build=$2 source=$3 relax=${4:-0}
    local -A domains=()
    local -A excluded=()
    local d a target active catchall localpart
    local mailbox_count=0 alias_count=0
    local -a domain_list=()
    local -a alias_domains=()
    local -a relay_all_domains=()

    for d in $EXCLUDE_DOMAINS; do
        excluded["${d,,}"]=1
    done

    while IFS=$'\t' read -r d active relay_all; do
        [[ -n $d ]] || continue
        [[ ${excluded[$d]:-} == 1 ]] && continue
        [[ "$active" == "true" ]] || continue
        if ! is_domain "$d"; then
            record_invalid "domain '$d'"
            continue
        fi
        domains["$d"]=1
        [[ "$relay_all" == "true" ]] && relay_all_domains+=("$d")
    done < <(jq -r '.[] | [.domain_name, (.active|tostring), (.relay_all_recipients|tostring)] | @tsv' "$dir/domains.json" | tr -d '\r')

    while IFS=$'\t' read -r a target active; do
        [[ -n $a ]] || continue
        [[ "$active" == "true" ]] || continue
        [[ ${excluded[$a]:-} == 1 ]] && continue
        if ! is_domain "$a" || ! is_domain "$target"; then
            record_invalid "alias domain '$a' -> '$target'"
            continue
        fi
        [[ ${domains[$target]:-} == 1 ]] || continue
        domains["$a"]=1
        alias_domains+=("$a")
    done < <(jq -r '.[] | [.alias_domain, .target_domain, (.active|tostring)] | @tsv' "$dir/alias_domains.json" | tr -d '\r')

    if (( ${#domains[@]} > 0 )); then
        mapfile -t domain_list < <(printf '%s\n' "${!domains[@]}" | sort -u)
    fi

    : >"$build/relay_domains"
    : >"$build/transport"
    for d in "${domain_list[@]}"; do
        printf '%s\tOK\n' "$d" >>"$build/relay_domains"
        printf '%s\tsmtp:[%s]:%s\n' "$d" "$MAILCOW_PRIMARY_IP" "$MAILCOW_PRIMARY_PORT" >>"$build/transport"
    done

    : >"$build/recipients.exact"
    while IFS= read -r a; do
        [[ -n $a ]] || continue
        if ! is_email "$a"; then
            record_invalid "mailbox '$a'"
            continue
        fi
        d=${a##*@}
        [[ ${domains[$d]:-} == 1 ]] || continue
        printf '%s\tOK\n' "$a" >>"$build/recipients.exact"
        mailbox_count=$((mailbox_count + 1))
    done < <(jq -r '.[] | select(.active) | .username' "$dir/mailboxes.json" | tr -d '\r')

    : >"$build/wildcards"
    while IFS=$'\t' read -r a catchall active; do
        [[ -n $a ]] || continue
        [[ "$active" == "true" ]] || continue
        if [[ $a == @* ]]; then
            d=${a#@}
            if ! is_domain "$d"; then
                record_invalid "catch-all '$a'"
                continue
            fi
            [[ ${domains[$d]:-} == 1 ]] || continue
            printf '@%s\n' "$d" >>"$build/wildcards"
            alias_count=$((alias_count + 1))
            continue
        fi
        if ! is_email "$a"; then
            record_invalid "alias '$a'"
            continue
        fi
        d=${a##*@}
        [[ ${domains[$d]:-} == 1 ]] || continue
        printf '%s\tOK\n' "$a" >>"$build/recipients.exact"
        alias_count=$((alias_count + 1))
        if [[ "$catchall" == "true" ]]; then
            printf '@%s\n' "$d" >>"$build/wildcards"
        fi
    done < <(jq -r '.[] | [.address, (.is_catch_all|tostring), (.active|tostring)] | @tsv' "$dir/aliases.json" | tr -d '\r')

    for d in "${alias_domains[@]}"; do
        printf '@%s\n' "$d" >>"$build/wildcards"
    done
    for d in "${relay_all_domains[@]}"; do
        printf '@%s\n' "$d" >>"$build/wildcards"
    done

    if [[ "$relax" -eq 1 ]]; then
        warn "relaxed mode: accepting every recipient for ${#domain_list[@]} hosted domains"
        for d in "${domain_list[@]}"; do
            printf '@%s\n' "$d" >>"$build/wildcards"
        done
    fi
    sort -u -o "$build/wildcards" "$build/wildcards"

    {
        cat "$build/recipients.exact"
        while IFS= read -r d; do
            [[ -n $d ]] && printf '%s\tOK\n' "$d"
        done <"$build/wildcards"
    } | sort -u >"$build/relay_recipients"

    case "$SMTP_TLS_MODE" in
        secure)
            printf '[%s]:%s\tsecure match=%s\n' \
                "$MAILCOW_PRIMARY_IP" "$MAILCOW_PRIMARY_PORT" "$SMTP_TLS_MATCH_HOSTNAME" >"$build/smtp_tls_policy"
            ;;
        may)
            printf '[%s]:%s\tmay\n' \
                "$MAILCOW_PRIMARY_IP" "$MAILCOW_PRIMARY_PORT" >"$build/smtp_tls_policy"
            ;;
    esac

    DOMAIN_COUNT=${#domain_list[@]}
    MAILBOX_COUNT=$mailbox_count
    ALIAS_COUNT=$alias_count
    ALIAS_DOMAIN_COUNT=${#alias_domains[@]}
    RECIPIENT_COUNT=$(wc -l <"$build/relay_recipients" | tr -d ' ')
    WILDCARD_COUNT=$(wc -l <"$build/wildcards" | tr -d ' ')
    SOURCE="$source"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
count_state() {
    local field=$1 value="0"
    if [[ -r "$STATE_FILE" ]]; then
        value=$(jq -r --arg f "$field" '(.counts[$f] // 0) | tostring' "$STATE_FILE" 2>/dev/null || printf '0')
    fi
    value=${value//$'\r'/}
    printf '%s' "${value:-0}"
}

state_epoch() {
    local value="0"
    if [[ -r "$STATE_FILE" ]]; then
        value=$(jq -r '(.last_api_success_epoch // 0) | tostring' "$STATE_FILE" 2>/dev/null || printf '0')
    fi
    value=${value//$'\r'/}
    printf '%s' "${value:-0}"
}

check_suspicious() {
    local prev_domains prev_mailboxes prev_recipients
    prev_domains=$(count_state domains)
    prev_mailboxes=$(count_state mailboxes)
    prev_recipients=$(count_state recipients)

    if [[ "$ALLOW_EMPTY" -eq 0 && "$DOMAIN_COUNT" -eq 0 ]]; then
        die "Mailcow reported no active domains; refusing to publish empty maps (use --allow-empty to accept)"
    fi
    if [[ "$FORCE" -eq 0 && "$DOMAIN_COUNT" -gt 0 && "$RECIPIENT_COUNT" -eq 0 ]]; then
        die "Mailcow reported $DOMAIN_COUNT domains but no valid recipients; refusing to publish maps (use --force to override)"
    fi
    [[ "$FORCE" -eq 1 ]] && return 0
    if (( prev_domains >= 5 )) && (( DOMAIN_COUNT * 2 < prev_domains )); then
        die "domain count dropped from $prev_domains to $DOMAIN_COUNT; refusing to publish (use --force to override)"
    fi
    if (( prev_mailboxes >= 10 )) && (( MAILBOX_COUNT * 2 < prev_mailboxes )); then
        die "mailbox count dropped from $prev_mailboxes to $MAILBOX_COUNT; refusing to publish (use --force to override)"
    fi
    if (( prev_recipients >= 20 )) && (( RECIPIENT_COUNT * 2 < prev_recipients )); then
        die "recipient count dropped from $prev_recipients to $RECIPIENT_COUNT; refusing to publish (use --force to override)"
    fi
    return 0
}

validate_maps() {
    local build=$1 line
    if [[ "$INVALID_COUNT" -gt 0 && "$FORCE" -eq 0 ]]; then
        die "Mailcow returned $INVALID_COUNT invalid entries (e.g. ${INVALID_SAMPLES[*]}); refusing to publish (use --force to skip them)"
    fi
    [[ "$INVALID_COUNT" -gt 0 ]] && warn "skipping $INVALID_COUNT invalid entries"

    while IFS= read -r line; do
        [[ $line =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*[[:space:]]+OK$ ]] \
            || die "invalid relay_domains line: $line"
    done <"$build/relay_domains"

    while IFS= read -r line; do
        [[ $line =~ ^(@?[^[:space:]]+)[[:space:]]+OK$ ]] \
            || die "invalid relay_recipients line: $line"
    done <"$build/relay_recipients"

    while IFS= read -r line; do
        [[ $line =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*[[:space:]]+smtp:\[[0-9a-fA-F:.]+\]:[0-9]+$ ]] \
            || die "invalid transport line: $line"
    done <"$build/transport"

    while IFS= read -r line; do
        [[ $line =~ ^\[[0-9a-fA-F:.]+\]:[0-9]+[[:space:]]+(may|secure[[:space:]]+match=[a-z0-9.-]+)$ ]] \
            || die "invalid smtp_tls_policy line: $line"
    done <"$build/smtp_tls_policy"

    if [[ ! -s "$build/relay_domains" && "$ALLOW_EMPTY" -ne 1 ]]; then
        die "generated relay_domains map is empty"
    fi
    return 0
}

build_databases() {
    local build=$1 name key
    for name in "${MAP_NAMES[@]}"; do
        [[ -f "$build/$name" ]] || die "internal error: missing $name"
        postmap "hash:$build/$name" >>"$LOG_FILE" 2>&1 \
            || die "postmap failed for $name"
    done
    if [[ -s "$build/relay_domains" ]]; then
        key=$(head -n 1 "$build/relay_domains")
        key=${key%%[[:space:]]*}
        [[ -n $key ]] || die "cannot determine a sample relay domain"
        [[ -n $(postmap -q "$key" "hash:$build/relay_domains") ]] \
            || die "relay_domains index verification failed"
    fi
}

# ---------------------------------------------------------------------------
# Applying maps
# ---------------------------------------------------------------------------
snapshot_maps() {
    local dir name keep_dir=${1:-}
    local -a old=()
    dir="$MXB_BACKUP_DIR/maps-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
    mkdir -p "$dir"
    for name in "${MAP_NAMES[@]}"; do
        [[ -f "$MXB_MAPS_DIR/$name" ]] && cp -p "$MXB_MAPS_DIR/$name" "$dir/$name"
        [[ -f "$MXB_MAPS_DIR/$name.db" ]] && cp -p "$MXB_MAPS_DIR/$name.db" "$dir/$name.db"
    done
    if [[ -r "$STATE_FILE" ]]; then
        jq '{counts: (.counts // {}), last_api_success_epoch: (.last_api_success_epoch // 0)}' \
            "$STATE_FILE" >"$dir/meta.json" 2>/dev/null || true
    fi
    SNAPSHOT_DIR="$dir"
    mapfile -t old < <(find "$MXB_BACKUP_DIR" -maxdepth 1 -type d -name 'maps-*' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | awk -v keep="$MAX_MAP_BACKUPS" -v keep_dir="$keep_dir" 'NR > keep && $2 != keep_dir {print $2}')
    if (( ${#old[@]} > 0 )); then
        rm -rf -- "${old[@]}"
    fi
}

maps_differ() {
    local build=$1 name key value
    for name in "${MAP_NAMES[@]}"; do
        if [[ ! -f "$MXB_MAPS_DIR/$name" ]] || ! cmp -s "$build/$name" "$MXB_MAPS_DIR/$name"; then
            return 0
        fi
        # Postfix reads the indexed file, not the text file. Repair a missing
        # index, or one that is older than its text source, even when the text
        # content itself is unchanged.
        if [[ ! -f "$MXB_MAPS_DIR/$name.db" ]]; then
            return 0
        fi
        if [[ "$MXB_MAPS_DIR/$name.db" -ot "$MXB_MAPS_DIR/$name" ]]; then
            return 0
        fi
        # A present index can still be corrupt. Probe the first rendered entry
        # against the installed index; an empty or wrong result means rebuild.
        if [[ -s "$build/$name" ]]; then
            IFS=$'\t' read -r key value < <(head -n 1 "$build/$name")
            if [[ -z "$value" ]]; then
                return 0
            fi
            if [[ "$(postmap -q "$key" "hash:$MXB_MAPS_DIR/$name" 2>/dev/null)" != "$value" ]]; then
                return 0
            fi
        fi
    done
    return 1
}

install_maps() {
    local build=$1 name
    for name in "${MAP_NAMES[@]}"; do
        chmod 0644 "$build/$name" "$build/$name.db"
        if [[ "$(id -u)" -eq 0 ]]; then
            chown root:root "$build/$name" "$build/$name.db" 2>/dev/null || true
        fi
        mv -f "$build/$name" "$MXB_MAPS_DIR/$name"
        mv -f "$build/$name.db" "$MXB_MAPS_DIR/$name.db"
    done
    if [[ "$(id -u)" -eq 0 ]]; then
        chown root:root "$MXB_MAPS_DIR"/*.db 2>/dev/null || true
    fi
}

reload_postfix() {
    [[ "$NO_RELOAD" -eq 1 ]] && { warn "not reloading Postfix (--no-reload)"; return 0; }
    postfix reload >>"$LOG_FILE" 2>&1 || return 1
    postfix status >>"$LOG_FILE" 2>&1 || return 1
    return 0
}

restore_snapshot() {
    local dir=$1 name restored=0
    [[ -d "$dir" ]] || die "snapshot not found: $dir"
    for name in "${MAP_NAMES[@]}"; do
        if [[ ! -f "$dir/$name" ]]; then
            warn "snapshot $dir has no $name; leaving the current file in place"
            continue
        fi
        cp -p "$dir/$name" "$MXB_MAPS_DIR/$name"
        if [[ -f "$dir/$name.db" ]]; then
            cp -p "$dir/$name.db" "$MXB_MAPS_DIR/$name.db"
        else
            postmap "hash:$MXB_MAPS_DIR/$name" >>"$LOG_FILE" 2>&1 \
                || die "postmap failed while restoring $name"
        fi
        restored=$((restored + 1))
    done
    (( restored > 0 )) || die "snapshot $dir contains no usable maps"
}

write_state() {
    local status=$1 message=$2 api_success_epoch=$3 relaxed=$4 duration_ms=$5
    local now tmp
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    tmp="$STATE_FILE.tmp.$$"
    jq -n \
        --arg version "$VERSION" \
        --arg now "$now" \
        --arg status "$status" \
        --arg message "$message" \
        --arg source "$SOURCE" \
        --argjson domains "$DOMAIN_COUNT" \
        --argjson mailboxes "$MAILBOX_COUNT" \
        --argjson aliases "$ALIAS_COUNT" \
        --argjson alias_domains "$ALIAS_DOMAIN_COUNT" \
        --argjson recipients "$RECIPIENT_COUNT" \
        --argjson wildcards "$WILDCARD_COUNT" \
        --argjson relaxed "$relaxed" \
        --argjson relax_after_days "$RELAX_AFTER_DAYS" \
        --argjson api_epoch "$api_success_epoch" \
        --argjson duration "$duration_ms" \
        '{
            schema_version: 1,
            script_version: $version,
            status: $status,
            message: $message,
            source: $source,
            last_attempt_at: $now,
            last_success_at: (if $status == "error" then null else $now end),
            last_api_success_at: (if $api_epoch > 0 then ($api_epoch | todate) else null end),
            last_api_success_epoch: $api_epoch,
            counts: {
                domains: $domains,
                mailboxes: $mailboxes,
                aliases: $aliases,
                alias_domains: $alias_domains,
                recipients: $recipients,
                wildcards: $wildcards
            },
            relaxed: ($relaxed == 1),
            relax_after_days: $relax_after_days,
            duration_ms: $duration
        }' >"$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

write_error_state() {
    local message=$1 now
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if [[ -n "$PREV_STATE" && -f "$PREV_STATE" ]]; then
        if jq --arg now "$now" --arg msg "$message" \
            '.status = "error" | .message = $msg | .last_attempt_at = $now | .duration_ms = 0' \
            "$PREV_STATE" >"$STATE_FILE.tmp.$$" 2>/dev/null; then
            mv -f "$STATE_FILE.tmp.$$" "$STATE_FILE"
            return 0
        fi
        rm -f -- "$STATE_FILE.tmp.$$"
    fi
    write_state "error" "$message" "$(state_epoch)" 0 0
}

update_cache() {
    local dir=$1 name
    for name in domains mailboxes aliases alias_domains; do
        cp -f "$dir/$name.json" "$CACHE_DIR/$name.json.tmp.$$"
        mv -f "$CACHE_DIR/$name.json.tmp.$$" "$CACHE_DIR/$name.json"
    done
    chmod 0640 "$CACHE_DIR"/*.json 2>/dev/null || true
}

cache_is_usable() {
    local name
    for name in domains mailboxes aliases alias_domains; do
        [[ -s "$CACHE_DIR/$name.json" ]] || return 1
        jq -e 'type == "array"' "$CACHE_DIR/$name.json" >/dev/null 2>&1 || return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --force) FORCE=1 ;;
            --allow-empty) ALLOW_EMPTY=1 ;;
            --no-reload) NO_RELOAD=1 ;;
            --no-postfix-check) NO_POSTFIX_CHECK=1 ;;
            --quiet) QUIET=1 ;;
            --verbose) : ;;
            --rollback)
                if [[ ${2:-} != "" && ${2:-} != -* ]]; then
                    ROLLBACK_TARGET=$2
                    shift
                else
                    ROLLBACK_TARGET="latest"
                fi
                ;;
            -h|--help) usage; exit 0 ;;
            -V|--version) printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
            *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done
}

do_rollback() {
    local want=$1 dir=""
    if [[ "$want" == "latest" ]]; then
        dir=$(find "$MXB_BACKUP_DIR" -maxdepth 1 -type d -name 'maps-*' -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | awk 'NR==1 {print $2}')
    elif [[ -d "$want" ]]; then
        dir=$(cd -- "$want" && pwd)
    else
        dir="$MXB_BACKUP_DIR/maps-$want"
    fi
    [[ -n "$dir" && -d "$dir" ]] || die "no map snapshot found${want:+ for '$want'}"
    log "rolling back maps from $dir"
    snapshot_maps "$dir"
    restore_snapshot "$dir"
    reload_postfix || die "Postfix failed to reload after rollback"
    SOURCE="rollback"
    local api_epoch
    if [[ -r "$dir/meta.json" ]]; then
        DOMAIN_COUNT=$(jq -r '.counts.domains // 0' "$dir/meta.json" 2>/dev/null || printf '0')
        MAILBOX_COUNT=$(jq -r '.counts.mailboxes // 0' "$dir/meta.json" 2>/dev/null || printf '0')
        ALIAS_COUNT=$(jq -r '.counts.aliases // 0' "$dir/meta.json" 2>/dev/null || printf '0')
        ALIAS_DOMAIN_COUNT=$(jq -r '.counts.alias_domains // 0' "$dir/meta.json" 2>/dev/null || printf '0')
        RECIPIENT_COUNT=$(jq -r '.counts.recipients // 0' "$dir/meta.json" 2>/dev/null || printf '0')
        WILDCARD_COUNT=$(jq -r '.counts.wildcards // 0' "$dir/meta.json" 2>/dev/null || printf '0')
        api_epoch=$(jq -r '.last_api_success_epoch // 0' "$dir/meta.json" 2>/dev/null || printf '0')
    else
        DOMAIN_COUNT=$(count_state domains)
        MAILBOX_COUNT=$(count_state mailboxes)
        ALIAS_COUNT=$(count_state aliases)
        ALIAS_DOMAIN_COUNT=$(count_state alias_domains)
        RECIPIENT_COUNT=$(count_state recipients)
        WILDCARD_COUNT=$(count_state wildcards)
        api_epoch=$(state_epoch)
    fi
    write_state "ok" "restored snapshot $(basename "$dir")" "$api_epoch" 0 0
    log "rollback complete"
}

main() {
    parse_args "$@"
    require_root
    prepare_dirs
    load_config
    validate_config

    if [[ -n "$ROLLBACK_TARGET" ]]; then
        acquire_lock
        postfix_uses_maps
        do_rollback "$ROLLBACK_TARGET"
        exit 0
    fi

    local start_s end_s duration=0
    start_s=$(date +%s)
    acquire_lock
    postfix_uses_maps

    WORK_DIR="$TMP_DIR/run-$$"
    rm -rf -- "$WORK_DIR"
    mkdir -p "$WORK_DIR/api"
    PREV_STATE="$TMP_DIR/prev-state-$$.json"
    [[ -r "$STATE_FILE" ]] && cp -f "$STATE_FILE" "$PREV_STATE"

    local api_ok=1
    if fetch_all "$WORK_DIR/api"; then
        if ! normalize_all "$WORK_DIR/api"; then
            err "Mailcow returned data that is not valid JSON"
            api_ok=0
        fi
    else
        api_ok=0
    fi

    local source="api" relax=0 api_epoch=0
    if [[ "$api_ok" -eq 0 ]]; then
        warn "Mailcow API unavailable, trying the local cache"
        if ! cache_is_usable; then
            write_error_state "API unavailable and no usable cache"
            die "synchronization failed: API unavailable and no usable cache; existing maps untouched"
        fi
        source="cache"
        local name
        for name in domains mailboxes aliases alias_domains; do
            cp -f "$CACHE_DIR/$name.json" "$WORK_DIR/api/$name.json"
        done
        api_epoch=$(state_epoch)
        if [[ "$RELAX_AFTER_DAYS" -gt 0 && "$api_epoch" -gt 0 ]]; then
            local age_days=$(( ( $(date +%s) - api_epoch ) / 86400 ))
            if (( age_days >= RELAX_AFTER_DAYS )); then
                relax=1
                log "CRITICAL: no successful API synchronization for ${age_days} days (threshold ${RELAX_AFTER_DAYS}); enabling relaxed recipient acceptance"
            fi
        fi
    else
        api_epoch=$(date +%s)
    fi

    local build
    if [[ "$DRY_RUN" -eq 1 ]]; then
        build="$WORK_DIR/maps"
        mkdir -p "$build"
    else
        build="$MXB_MAPS_DIR/.build.$$"
        mkdir -p "$build"
        BUILD_DIR="$build"
    fi

    render_maps "$WORK_DIR/api" "$build" "$source" "$relax"
    check_suspicious
    validate_maps "$build"
    build_databases "$build"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        local changed=0
        maps_differ "$build" && changed=1
        log "dry run: source=$source domains=$DOMAIN_COUNT mailboxes=$MAILBOX_COUNT aliases=$ALIAS_COUNT recipients=$RECIPIENT_COUNT wildcards=$WILDCARD_COUNT changed=$changed relaxed=$relax"
        [[ "$QUIET" -eq 0 ]] && printf 'dry-run source=%s domains=%s mailboxes=%s aliases=%s recipients=%s wildcards=%s changed=%s relaxed=%s\n' \
            "$source" "$DOMAIN_COUNT" "$MAILBOX_COUNT" "$ALIAS_COUNT" "$RECIPIENT_COUNT" "$WILDCARD_COUNT" "$changed" "$relax"
        exit 0
    fi

    local changed=0
    maps_differ "$build" && changed=1

    if [[ "$changed" -eq 1 ]]; then
        snapshot_maps
        install_maps "$build"
        if ! reload_postfix; then
            err "Postfix failed to reload after installing maps; restoring the previous snapshot"
            restore_snapshot "$SNAPSHOT_DIR"
            reload_postfix || err "Postfix still fails after restoring the snapshot"
            write_error_state "map installation failed, previous maps restored"
            exit 1
        fi
    else
        log "maps are unchanged; Postfix reload not required"
    fi

    [[ "$api_ok" -eq 1 ]] && update_cache "$WORK_DIR/api"

    end_s=$(date +%s)
    (( end_s >= start_s )) && duration=$(( (end_s - start_s) * 1000 ))

    local status="ok" message="synchronized from Mailcow API"
    if [[ "$relax" -eq 1 ]]; then
        status="relaxed"
        message="recipient validation relaxed after prolonged API outage"
    elif [[ "$api_ok" -eq 0 ]]; then
        status="degraded"
        message="Mailcow API unavailable; maps rebuilt from cache"
    fi

    write_state "$status" "$message" "$api_epoch" "$relax" "$duration"
    log "synchronization complete: source=$source status=$status domains=$DOMAIN_COUNT mailboxes=$MAILBOX_COUNT aliases=$ALIAS_COUNT recipients=$RECIPIENT_COUNT wildcards=$WILDCARD_COUNT changed=$changed"
    exit 0
}

main "$@"
