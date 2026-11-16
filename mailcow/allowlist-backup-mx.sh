#!/usr/bin/env bash
#
# allowlist-backup-mx.sh - let Mailcow trust the Mailcow Backup MX
#
# Runs ON THE MAILCOW HOST (inside /opt/mailcow-dockerized), not on the
# backup MX. It makes two independent changes:
#
#   1. adds the backup MX address to Mailcow's postscreen access list, so
#      greylisting and the DNSBL/greet delays never apply to it;
#   2. disables greylisting in rspamd for messages relayed by it, while spam,
#      virus, DKIM and SPF checks keep running.
#
# Mailcow sees every queued message as coming from the backup MX IP, because
# the backup MX relays for arbitrary senders; allowing that IP in rspamd's
# whitelist logic therefore means trusting whatever the backup MX forwards.
# That is why only the greylisting action is disabled here.
#
# Both changes live in files that Mailcow already includes but never
# generates, so "apt update && apt upgrade -y" followed by "./update.sh"
# cannot conflict with them. Re-run this script after each Mailcow update to
# repair any drift; it is idempotent and changes nothing when already applied.
#
# Part of mx-backup-mailcow. Standalone script: no shared libraries.
#
set -Eeuo pipefail

SCRIPT_NAME="mailcow-allowlist"

: "${MAILCOW_DIR:=/opt/mailcow-dockerized}"
: "${MXB_ALLOWLIST_STATE:=/etc/mailcow-backup-mx-allowlist.conf}"
: "${MXB_ALLOWLIST_BACKUP_DIR:=/var/backups/mailcow-backup-mx-allowlist}"
: "${MXB_ALLOWLIST_READY_TIMEOUT:=30}"

CIDR_BEGIN="# BEGIN mx-backup-mailcow (managed by allowlist-backup-mx.sh; do not edit)"
CIDR_END="# END mx-backup-mailcow"
RSPAMD_BEGIN="# BEGIN mx-backup-mailcow (managed by allowlist-backup-mx.sh; do not edit)"
RSPAMD_END="# END mx-backup-mailcow"
RSPAMD_RULE="mx_backup_mailcow_greylist"

PROG_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VERSION="unknown"
for version_file in "$PROG_DIR/../VERSION" "$PROG_DIR/VERSION" \
    "${PROG_DIR%/share/mailcow}/VERSION" "${PROG_DIR%/share/mailcow}/../VERSION"; do
    [[ -r "$version_file" ]] || continue
    VERSION=$(<"$version_file")
    VERSION=${VERSION//[[:space:]]/}
    [[ -n "$VERSION" ]] && break
done
[[ -n "$VERSION" ]] || VERSION="unknown"

MODE=apply
DRY_RUN=0
NO_RELOAD=0
OPT_CHECK=0
OPT_REMOVE=0
IPS=()
COMPOSE=()
TEMP_FILES=()

POSTFIX_CID=""
POSTFIX_CIDR_CONTAINER=""
POSTFIX_CIDR_HOST=""
RSPAMD_CID=""
RSPAMD_LOCAL_DIR=""
RSPAMD_SETTINGS_HOST=""

RUN_DIR=""
SNAPSHOT_DIR=""
POSTFIX_CHANGED=0
RSPAMD_CHANGED=0

usage() {
    cat <<'EOF'
Usage: allowlist-backup-mx.sh [OPTIONS]

Trust the Mailcow Backup MX on this Mailcow host: add it to the postscreen
access list and disable rspamd greylisting for messages it relays.

Options:
  --ip ADDR[/PREFIX]    Address of the backup MX (repeatable). Required on the
                        first run; later runs reuse the saved list.
  --check               Verify only; exit 1 if the files or configuration have
                        drifted (run after Mailcow updates).
  --remove              Remove the managed entries and the saved address list.
  --dry-run             Show what would change without writing or reloading.
  --no-reload           Write and validate, but do not reload Postfix or
                        restart rspamd.
  --mailcow-dir DIR     Mailcow installation (default: /opt/mailcow-dockerized)
  --state FILE          Saved address list (default: /etc/mailcow-backup-mx-allowlist.conf)
  -h, --help            Show this help
  -V, --version         Show script version

Exit status: 0 success (including --check with no drift), 1 drift or error.

Examples:
  # first run, on the Mailcow host
  sudo bash allowlist-backup-mx.sh --ip 188.245.221.122

  # after apt upgrades and ./update.sh, repair any drift
  sudo bash allowlist-backup-mx.sh

  # verify without changing anything
  sudo bash allowlist-backup-mx.sh --check
EOF
}

log() {
    printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$SCRIPT_NAME" "$*" >&2
}

warn() { log "WARN: $*"; }
err() { log "ERROR: $*"; }
die() { err "$*"; exit 1; }

on_error() {
    local rc=$? line=${1:-?}
    trap - ERR
    err "unexpected failure at line ${line} (exit ${rc})"
    exit "$rc"
}
trap 'on_error $LINENO' ERR

cleanup() {
    local rc=$? file
    trap - EXIT
    for file in "${TEMP_FILES[@]}"; do
        rm -f -- "$file" 2>/dev/null || true
    done
    [[ -n "$RUN_DIR" && -d "$RUN_DIR" ]] && rm -rf -- "$RUN_DIR" 2>/dev/null || true
    exit "$rc"
}
trap cleanup EXIT

parse_args() {
    local ip
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ip) ip=${2:?--ip requires an address}; IPS+=("$ip"); shift ;;
            --check) MODE=check; OPT_CHECK=1 ;;
            --remove) MODE=remove; OPT_REMOVE=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --no-reload) NO_RELOAD=1 ;;
            --mailcow-dir) MAILCOW_DIR=${2:?--mailcow-dir requires a directory}; shift ;;
            --state) MXB_ALLOWLIST_STATE=${2:?--state requires a file}; shift ;;
            -h|--help) usage; exit 0 ;;
            -V|--version) printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
            *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done
    if [[ "$MODE" == "remove" ]]; then
        [[ ${#IPS[@]} -eq 0 ]] || die "--remove cannot be combined with --ip"
    fi
    if [[ "$OPT_CHECK" -eq 1 && "$OPT_REMOVE" -eq 1 ]]; then
        die "--check and --remove cannot be combined"
    fi
    if [[ "$MODE" == "check" && ${#IPS[@]} -gt 0 ]]; then
        warn "--check verifies the installed configuration; --ip is ignored"
        IPS=()
    fi
}

require_root() {
    [[ "${MXB_SKIP_ROOT_CHECK:-0}" == "1" ]] && return 0
    [[ "$(id -u)" -eq 0 ]] || die "must be run as root (use sudo)"
}

require_mailcow() {
    [[ -d "$MAILCOW_DIR" ]] || die "Mailcow directory not found: $MAILCOW_DIR"
    [[ -f "$MAILCOW_DIR/docker-compose.yml" ]] \
        || die "$MAILCOW_DIR does not contain docker-compose.yml; use --mailcow-dir"
    [[ -d "$MAILCOW_DIR/data/conf/postfix" ]] \
        || die "$MAILCOW_DIR/data/conf/postfix is missing; is this a Mailcow installation?"
}

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE=(docker compose)
    elif docker-compose version >/dev/null 2>&1; then
        COMPOSE=(docker-compose)
    else
        die "neither 'docker compose' nor 'docker-compose' is available"
    fi
}

compose() {
    ( cd -- "$MAILCOW_DIR" && "${COMPOSE[@]}" "$@" )
}

service_container() {
    local service=$1 cid
    cid=$(compose ps -q "$service" 2>/dev/null | head -n 1) || true
    [[ -n "$cid" ]] \
        || die "the Mailcow container '$service' is not running; start Mailcow first"
    printf '%s' "$cid"
}

mounts_of() {
    docker inspect -f '{{range .Mounts}}{{.Destination}}={{.Source}}{{"\n"}}{{end}}' "$1"
}

# Translate a path inside a container to the path on this host, using the
# longest matching bind mount. Fails when the path is not backed by a mount.
container_to_host() {
    local cid=$1 cpath=$2 dest src best_dest="" best_src="" len
    cpath=${cpath%/}
    while IFS='=' read -r dest src; do
        [[ -n "$dest" && -n "$src" ]] || continue
        dest=${dest%/}
        if [[ "$cpath" == "$dest" || "$cpath" == "$dest"/* ]]; then
            len=${#dest}
            if (( len > ${#best_dest} )); then
                best_dest=$dest
                best_src=${src%/}
            fi
        fi
    done < <(mounts_of "$cid")
    [[ -n "$best_dest" ]] || return 1
    printf '%s%s' "$best_src" "${cpath#"$best_dest"}"
}

discover_postfix() {
    local access entry
    POSTFIX_CID=$(service_container postfix-mailcow)
    access=$(compose exec -T postfix-mailcow postconf -h postscreen_access_list 2>/dev/null) \
        || die "cannot read postscreen_access_list inside postfix-mailcow"

    while IFS= read -r entry; do
        [[ "$entry" == cidr:* ]] || continue
        case "$entry" in
            *custom_postscreen_whitelist.cidr)
                POSTFIX_CIDR_CONTAINER=${entry#cidr:}
                ;;
        esac
    done < <(printf '%s' "$access" | tr ',' '\n' | sed 's/[[:space:]]//g')

    if [[ -z "$POSTFIX_CIDR_CONTAINER" ]]; then
        die "postscreen_access_list does not reference custom_postscreen_whitelist.cidr (found: ${access:-empty}). This Mailcow release changed the postscreen configuration; extend this script after inspecting 'postconf -h postscreen_access_list' inside postfix-mailcow."
    fi

    POSTFIX_CIDR_HOST=$(container_to_host "$POSTFIX_CID" "$POSTFIX_CIDR_CONTAINER") \
        || die "$POSTFIX_CIDR_CONTAINER is not inside a bind mount of postfix-mailcow"

    case "$POSTFIX_CIDR_HOST" in
        "$MAILCOW_DIR"/*) ;;
        *) die "refusing to write outside $MAILCOW_DIR (resolved to $POSTFIX_CIDR_HOST)" ;;
    esac
}

discover_rspamd() {
    local local_dir_container=/etc/rspamd/local.d
    RSPAMD_CID=$(service_container rspamd-mailcow)
    RSPAMD_LOCAL_DIR=$(container_to_host "$RSPAMD_CID" "$local_dir_container") \
        || die "$local_dir_container is not inside a bind mount of rspamd-mailcow"
    case "$RSPAMD_LOCAL_DIR" in
        "$MAILCOW_DIR"/*) ;;
        *) die "refusing to write outside $MAILCOW_DIR (resolved to $RSPAMD_LOCAL_DIR)" ;;
    esac
    [[ -d "$RSPAMD_LOCAL_DIR" ]] \
        || die "$RSPAMD_LOCAL_DIR does not exist on this host"
    RSPAMD_SETTINGS_HOST="$RSPAMD_LOCAL_DIR/settings.conf"
}

normalize_ip() {
    local value=${1,,} addr prefix
    [[ -n "$value" ]] || return 1
    if [[ "$value" == */* ]]; then
        addr=${value%/*}
        prefix=${value##*/}
    else
        addr=$value
        prefix=""
    fi
    if [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local o
        for o in ${addr//./ }; do
            (( o >= 0 && o <= 255 )) || return 1
        done
        [[ -z "$prefix" ]] && prefix=32
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
        (( prefix >= 0 && prefix <= 32 )) || return 1
        printf '%s/%s' "$addr" "$prefix"
        return 0
    fi
    if [[ "$addr" == *:* && "$addr" =~ ^[0-9a-f:]+$ ]]; then
        [[ -z "$prefix" ]] && prefix=128
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
        (( prefix >= 0 && prefix <= 128 )) || return 1
        printf '%s/%s' "$addr" "$prefix"
        return 0
    fi
    return 1
}

normalize_ips() {
    local raw normalized
    local -a result=()
    for raw in "${IPS[@]}"; do
        normalized=$(normalize_ip "$raw") \
            || die "not a valid IP address or network: $raw"
        result+=("$normalized")
    done
    IPS=()
    if (( ${#result[@]} > 0 )); then
        mapfile -t IPS < <(printf '%s\n' "${result[@]}" | sort -u)
    fi
}

read_state_ips() {
    [[ -r "$MXB_ALLOWLIST_STATE" ]] || return 1
    local -a saved=()
    # shellcheck disable=SC1090,SC1091
    . "$MXB_ALLOWLIST_STATE"
    [[ ${#saved[@]} -gt 0 ]] || return 1
    IPS=("${saved[@]}")
    return 0
}

read_block_ips() {
    local file=$1 begin=$2 end=$3 value
    [[ -r "$file" ]] || return 1
    local -a found=()
    while IFS= read -r value; do
        [[ -n "$value" ]] && found+=("$value")
    done < <(awk -v b="$begin" -v e="$end" '
        $0 == b {inside = 1; next}
        inside && $0 == e {inside = 0; next}
        inside && $0 !~ /^[[:space:]]*#/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            sub(/,$/, "")
            gsub(/^"|"$/, "")
            sub(/[[:space:]]+permit$/, "")
            if (length($0) > 0) print
        }
    ' "$file")
    [[ ${#found[@]} -gt 0 ]] || return 1
    IPS=("${found[@]}")
    return 0
}

# The rspamd settings block is HCL, not a CIDR list: only the quoted addresses
# inside "ip = [ ... ]" are addresses. Parsing every non-comment line yields
# rule and action names, which normalize_ips would reject.
read_rspamd_ips() {
    local file=$1 begin=$2 end=$3 value
    [[ -r "$file" ]] || return 1
    local -a found=()
    while IFS= read -r value; do
        [[ -n "$value" ]] && found+=("$value")
    done < <(awk -v b="$begin" -v e="$end" '
        $0 == b {inside = 1; next}
        inside && $0 == e {inside = 0; next}
        inside && match($0, /"[0-9a-fA-F:.\/]+"/) {
            print substr($0, RSTART + 1, RLENGTH - 2)
        }
    ' "$file")
    [[ ${#found[@]} -gt 0 ]] || return 1
    IPS=("${found[@]}")
    return 0
}

resolve_desired_ips() {
    [[ "$MODE" == "remove" ]] && return 0
    if (( ${#IPS[@]} > 0 )); then
        normalize_ips
        return 0
    fi
    if read_state_ips; then
        normalize_ips
        return 0
    fi
    if read_block_ips "$POSTFIX_CIDR_HOST" "$CIDR_BEGIN" "$CIDR_END"; then
        normalize_ips
        return 0
    fi
    if read_rspamd_ips "$RSPAMD_SETTINGS_HOST" "$RSPAMD_BEGIN" "$RSPAMD_END"; then
        normalize_ips
        return 0
    fi
    if [[ "$MODE" == "check" ]]; then
        log "no managed allowlist is installed; nothing to check"
        exit 0
    fi
    usage >&2
    die "no address to apply: pass --ip ADDR (for example --ip 188.245.221.122)"
}

render_cidr_block() {
    printf '%s\n' "$CIDR_BEGIN"
    local ip
    for ip in "${IPS[@]}"; do
        printf '%s\tpermit\n' "$ip"
    done
    printf '%s\n' "$CIDR_END"
}

render_rspamd_block() {
    local ip
    printf '%s\n' "$RSPAMD_BEGIN"
    printf '%s {\n' "$RSPAMD_RULE"
    printf '  priority = high;\n'
    printf '  ip = [\n'
    for ip in "${IPS[@]}"; do
        printf '    "%s",\n' "$ip"
    done
    printf '  ];\n'
    printf '  apply {\n'
    printf '    actions {\n'
    printf '      greylist = null;\n'
    printf '    }\n'
    printf '  }\n'
    printf '}\n'
    printf '%s\n' "$RSPAMD_END"
}

render_state() {
    printf '# Managed by allowlist-backup-mx.sh on the Mailcow host. Do not edit.\n'
    printf 'saved=(\n'
    local ip
    for ip in "${IPS[@]}"; do
        printf '  %q\n' "$ip"
    done
    printf ')\n'
}

# Remove the managed block from "$file" (if present) and append "$block".
build_content() {
    local file=$1 begin=$2 end=$3 block=$4 without=""
    if [[ -f "$file" ]]; then
        without=$(awk -v b="$begin" -v e="$end" '
            $0 == b {skip = 1; next}
            skip && $0 == e {skip = 0; next}
            !skip {print}
        ' "$file")
    fi
    if [[ -n "$block" ]]; then
        if [[ -n "$without" ]]; then
            printf '%s\n\n%s\n' "$without" "$block"
        else
            printf '%s\n' "$block"
        fi
    elif [[ -n "$without" ]]; then
        printf '%s\n' "$without"
    fi
}

file_matches() {
    local path=$1 content=$2 tmp
    tmp="$RUN_DIR/compare.$$"
    printf '%s' "$content" >"$tmp"
    [[ -f "$path" ]] && cmp -s "$tmp" "$path"
}

snapshot() {
    local path=$1 name manifest
    mkdir -p "$SNAPSHOT_DIR"
    manifest="$SNAPSHOT_DIR/manifest"
    name=${path#"$MAILCOW_DIR"/}
    name=${name//\//_}
    if [[ -e "$path" ]]; then
        cp -p -- "$path" "$SNAPSHOT_DIR/$name" || die "cannot back up $path"
        printf 'present\t%s\t%s\n' "$path" "$name" >>"$manifest"
    else
        printf 'absent\t%s\t%s\n' "$path" "$name" >>"$manifest"
    fi
}

restore_snapshot() {
    local state path name
    [[ -n "$SNAPSHOT_DIR" && -f "$SNAPSHOT_DIR/manifest" ]] || return 0
    while IFS=$'\t' read -r state path name; do
        if [[ "$state" == "present" ]]; then
            cp -p -- "$SNAPSHOT_DIR/$name" "$path" || warn "cannot restore $path"
        else
            rm -f -- "$path" || warn "cannot remove $path"
        fi
    done <"$SNAPSHOT_DIR/manifest"
}

prune_backups() {
    local old
    local -a candidates=()
    [[ -d "$MXB_ALLOWLIST_BACKUP_DIR" ]] || return 0
    mapfile -t candidates < <(find "$MXB_ALLOWLIST_BACKUP_DIR" -mindepth 1 -maxdepth 1 \
        -type d -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk 'NR > 10 {print $2}')
    for old in "${candidates[@]}"; do
        rm -rf -- "$old"
    done
}

# Write $content to $path atomically, preserving mode and owner of an existing
# file. The temporary file lives in the same directory so the rename cannot be
# observed half-written, even if this script is killed mid-write.
write_content() {
    local path=$1 content=$2 new_mode=${3:-0644} tmp mode owner
    tmp="$(dirname -- "$path")/.$(basename -- "$path").mxb-allowlist.$$"
    TEMP_FILES+=("$tmp")
    printf '%s' "$content" >"$tmp"
    if [[ -f "$path" ]]; then
        mode=$(stat -c '%a' "$path")
        owner=$(stat -c '%u:%g' "$path")
        chmod "$mode" "$tmp"
        if [[ "$(id -u)" -eq 0 ]]; then
            chown "$owner" "$tmp" || die "cannot preserve the owner of $path"
        fi
    else
        chmod "$new_mode" "$tmp"
    fi
    mv -f -- "$tmp" "$path" || die "cannot write $path"
    local kept=() entry
    for entry in "${TEMP_FILES[@]}"; do
        [[ "$entry" == "$tmp" ]] || kept+=("$entry")
    done
    TEMP_FILES=("${kept[@]}")
}

validate_postfix_cidr() {
    local ip plain result
    for ip in "${IPS[@]}"; do
        plain=${ip%%/*}
        if ! result=$(compose exec -T postfix-mailcow postmap -q "$plain" \
            "cidr:$POSTFIX_CIDR_CONTAINER" 2>&1); then
            err "postfix could not look up $plain in $POSTFIX_CIDR_CONTAINER: $result"
            return 1
        fi
        if [[ "$result" != "permit" ]]; then
            err "$plain resolves to '$result' instead of 'permit' in $POSTFIX_CIDR_CONTAINER; an earlier entry in the file may override it"
            return 1
        fi
    done
    return 0
}

validate_rspamd() {
    local output rc=0
    output=$(compose exec -T rspamd-mailcow rspamadm configtest 2>&1) || rc=$?
    if (( rc != 0 )); then
        err "rspamadm configtest failed: $output"
        return 1
    fi
    if [[ "$MODE" == "remove" ]]; then
        return 0
    fi
    output=$(compose exec -T rspamd-mailcow rspamadm configdump settings 2>&1) || rc=$?
    if (( rc != 0 )); then
        err "rspamadm configdump failed: $output"
        return 1
    fi
    if ! printf '%s' "$output" | grep -q "$RSPAMD_RULE"; then
        err "the rspamd rule $RSPAMD_RULE is not in the effective configuration; $RSPAMD_SETTINGS_HOST is not being merged"
        return 1
    fi
    return 0
}

wait_for_rspamd() {
    local waited=0
    while (( waited < MXB_ALLOWLIST_READY_TIMEOUT )); do
        if compose exec -T rspamd-mailcow rspamadm control stat >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

reload_services() {
    if [[ "$POSTFIX_CHANGED" -eq 1 ]]; then
        compose exec -T postfix-mailcow postfix reload \
            || rollback "Postfix failed to reload; the previous files were restored"
        log "postfix reloaded"
    fi
    if [[ "$RSPAMD_CHANGED" -eq 1 ]]; then
        # rspamd reloads maps dynamically, but local.d configuration is core
        # configuration and only a restart makes it effective.
        compose restart rspamd-mailcow >/dev/null \
            || rollback "rspamd-mailcow failed to restart; the previous files were restored"
        wait_for_rspamd \
            || rollback "rspamd-mailcow did not become ready within ${MXB_ALLOWLIST_READY_TIMEOUT}s; the previous files were restored"
        log "rspamd restarted with the new configuration"
    fi
}

rollback() {
    local reason=$1
    if [[ -n "$SNAPSHOT_DIR" && -f "$SNAPSHOT_DIR/manifest" ]]; then
        log "rolling back the file changes"
        restore_snapshot
    fi
    if [[ "$POSTFIX_CHANGED" -eq 1 ]]; then
        compose exec -T postfix-mailcow postfix reload >/dev/null 2>&1 \
            || warn "postfix reload after rollback failed; run: docker compose exec -T postfix-mailcow postfix reload"
    fi
    if [[ "$RSPAMD_CHANGED" -eq 1 ]]; then
        compose restart rspamd-mailcow >/dev/null 2>&1 \
            || warn "rspamd restart after rollback failed; run: docker compose restart rspamd-mailcow"
        wait_for_rspamd \
            || warn "rspamd is not ready after the rollback; inspect: docker compose logs rspamd-mailcow"
    fi
    die "$reason"
}

show_diff() {
    local path=$1 content=$2 tmp="$RUN_DIR/diff.$$"
    printf '%s' "$content" >"$tmp"
    if [[ -f "$path" ]]; then
        diff -u --label "$path (current)" --label "$path (desired)" "$path" "$tmp" || true
    else
        diff -u --label "$path (missing)" --label "$path (desired)" /dev/null "$tmp" || true
    fi
}

desired_content() {
    local kind=$1 block=""
    if [[ "$MODE" != "remove" ]]; then
        case "$kind" in
            cidr) block=$(render_cidr_block) ;;
            rspamd) block=$(render_rspamd_block) ;;
        esac
    fi
    case "$kind" in
        cidr) build_content "$POSTFIX_CIDR_HOST" "$CIDR_BEGIN" "$CIDR_END" "$block" ;;
        rspamd) build_content "$RSPAMD_SETTINGS_HOST" "$RSPAMD_BEGIN" "$RSPAMD_END" "$block" ;;
        *) die "internal error: unknown content kind $kind" ;;
    esac
}

check_mode() {
    local drift=0 cidr_content rspamd_content
    cidr_content=$(desired_content cidr)
    rspamd_content=$(desired_content rspamd)

    if file_matches "$POSTFIX_CIDR_HOST" "$cidr_content"; then
        log "postscreen whitelist: in sync ($POSTFIX_CIDR_HOST)"
    else
        warn "postscreen whitelist: drift in $POSTFIX_CIDR_HOST"
        drift=1
    fi
    if file_matches "$RSPAMD_SETTINGS_HOST" "$rspamd_content"; then
        log "rspamd settings: in sync ($RSPAMD_SETTINGS_HOST)"
    else
        warn "rspamd settings: drift in $RSPAMD_SETTINGS_HOST"
        drift=1
    fi
    if ! read_state_ips; then
        warn "saved address list: missing or empty ($MXB_ALLOWLIST_STATE)"
        drift=1
    fi

    if (( drift == 1 )); then
        log "drift detected: run 'allowlist-backup-mx.sh' (without --check) to repair it"
        return 1
    fi
    validate_postfix_cidr || return 1
    validate_rspamd || return 1
    log "no drift: Mailcow trusts ${IPS[*]}"
    return 0
}

apply_changes() {
    local cidr_content rspamd_content state_content changed=0
    cidr_content=$(desired_content cidr)
    rspamd_content=$(desired_content rspamd)
    if [[ "$MODE" == "remove" ]]; then
        state_content=""
    else
        state_content=$(render_state)
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "dry run: no file is written and no service is reloaded"
        show_diff "$POSTFIX_CIDR_HOST" "$cidr_content"
        show_diff "$RSPAMD_SETTINGS_HOST" "$rspamd_content"
        [[ "$MODE" == "remove" ]] || show_diff "$MXB_ALLOWLIST_STATE" "$state_content"
        return 0
    fi

    SNAPSHOT_DIR="$MXB_ALLOWLIST_BACKUP_DIR/$(date -u '+%Y%m%dT%H%M%SZ')-$$"

    if ! file_matches "$POSTFIX_CIDR_HOST" "$cidr_content"; then
        snapshot "$POSTFIX_CIDR_HOST"
        write_content "$POSTFIX_CIDR_HOST" "$cidr_content"
        POSTFIX_CHANGED=1
        changed=1
        log "updated $POSTFIX_CIDR_HOST"
    fi
    if ! file_matches "$RSPAMD_SETTINGS_HOST" "$rspamd_content"; then
        snapshot "$RSPAMD_SETTINGS_HOST"
        write_content "$RSPAMD_SETTINGS_HOST" "$rspamd_content"
        RSPAMD_CHANGED=1
        changed=1
        log "updated $RSPAMD_SETTINGS_HOST"
    fi

    if [[ "$MODE" == "remove" ]]; then
        if [[ -e "$MXB_ALLOWLIST_STATE" ]]; then
            changed=1
        fi
    fi

    if [[ "$changed" -eq 0 ]]; then
        if [[ "$MODE" != "remove" ]] && ! file_matches "$MXB_ALLOWLIST_STATE" "$state_content"; then
            write_content "$MXB_ALLOWLIST_STATE" "$state_content" 0600
            log "saved the address list in $MXB_ALLOWLIST_STATE"
        fi
        log "already applied; no Postfix or rspamd change needed"
        if [[ "$MODE" != "remove" ]]; then
            validate_postfix_cidr || die "the existing postscreen entry is not effective"
            validate_rspamd || die "the existing rspamd configuration is not effective"
        elif [[ -e "$MXB_ALLOWLIST_STATE" ]]; then
            rm -f -- "$MXB_ALLOWLIST_STATE"
            log "removed $MXB_ALLOWLIST_STATE"
        else
            log "nothing to remove"
        fi
        return 0
    fi

    # Validate before activating anything. A failure restores the previous
    # files so Mailcow keeps the configuration it had before this run.
    if [[ "$MODE" != "remove" ]]; then
        validate_postfix_cidr \
            || rollback "the new postscreen entry is not effective"
    fi
    validate_rspamd \
        || rollback "rspamd rejected the new configuration"

    if [[ "$NO_RELOAD" -eq 1 ]]; then
        warn "files written and validated; services were not reloaded (--no-reload)"
        warn "apply later with: ${COMPOSE[*]} exec -T postfix-mailcow postfix reload && ${COMPOSE[*]} restart rspamd-mailcow"
    else
        reload_services
    fi

    # Only record the new intent after the configuration is proven to load.
    if [[ "$MODE" == "remove" ]]; then
        rm -f -- "$MXB_ALLOWLIST_STATE"
        log "removed $MXB_ALLOWLIST_STATE"
    elif ! file_matches "$MXB_ALLOWLIST_STATE" "$state_content"; then
        write_content "$MXB_ALLOWLIST_STATE" "$state_content" 0600
        log "saved the address list in $MXB_ALLOWLIST_STATE"
    fi

    prune_backups
    if [[ "$MODE" == "remove" ]]; then
        log "removed the Mailcow allowlist for the backup MX"
    else
        log "Mailcow now trusts ${IPS[*]} (postscreen + rspamd greylisting)"
    fi
}

main() {
    parse_args "$@"
    require_root
    require_mailcow
    detect_compose
    discover_postfix
    discover_rspamd
    resolve_desired_ips
    RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mxb-allowlist.XXXXXX")

    if [[ "$MODE" == "check" ]]; then
        if check_mode; then
            exit 0
        fi
        exit 1
    fi

    apply_changes
}

main "$@"
