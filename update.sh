#!/usr/bin/env bash
#
# update.sh - update Ubuntu packages independently of the application
#
# Part of mx-backup-mailcow. Standalone script: no shared libraries.
#
# Performs a normal package upgrade (never a distribution upgrade), reports
# failures, lets needrestart restart affected services, and never reboots.
#
set -Eeuo pipefail

SCRIPT_NAME="update"
PROG_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

: "${MXB_STATE_DIR:=/var/lib/mailcow-backup-mx}"
: "${MXB_LOG_DIR:=/var/log/mailcow-backup-mx}"
: "${MXB_INSTALL_DIR:=/opt/mx-backup-mailcow}"
: "${MXB_REBOOT_MARKER:=/var/run/reboot-required}"
: "${MXB_REBOOT_PKGS:=/var/run/reboot-required.pkgs}"

LOG_FILE="$MXB_LOG_DIR/update.log"
STATE_FILE="$MXB_STATE_DIR/state/update-state.json"
RUN_DIR="$MXB_STATE_DIR/run"
LOCK_DIR="$RUN_DIR/update.lock"
APT_OUTPUT=""

QUIET=0
DRY_RUN=0
LOCK_HELD=0
LOCK_TMP=""

VERSION="unknown"
for version_file in "$PROG_DIR/../VERSION" "$PROG_DIR/VERSION" "$MXB_INSTALL_DIR/VERSION"; do
    [[ -r "$version_file" ]] || continue
    VERSION=$(<"$version_file")
    VERSION=${VERSION//[[:space:]]/}
    [[ -n "$VERSION" ]] && break
done
[[ -n "$VERSION" ]] || VERSION="unknown"

usage() {
    cat <<'EOF'
Usage: update.sh [OPTIONS]

Update Ubuntu packages. Never reboots and never performs a distribution
upgrade.

Options:
  --dry-run    Simulate the upgrade without changing anything
  --quiet      Only write to the log file
  -h, --help   Show this help
  -V, --version
EOF
}

log() {
    local line
    line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [$SCRIPT_NAME] $*"
    printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
    [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$line" >&2
}

die() {
    log "ERROR: $*"
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

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --quiet) QUIET=1 ;;
            -h|--help) usage; exit 0 ;;
            -V|--version) printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
            *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done
}

require_root() {
    [[ "${MXB_SKIP_ROOT_CHECK:-0}" == "1" ]] && return 0
    [[ "$(id -u)" -eq 0 ]] || die "must be run as root"
}

acquire_lock() {
    mkdir -p "$RUN_DIR" "$MXB_LOG_DIR" "$MXB_STATE_DIR/state"
    local pid="" attempt=0
    LOCK_TMP="$RUN_DIR/.update.lock.$$"
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
            die "another update is running (pid $pid)"
        fi
        log "WARN: removing stale update lock"
        rm -rf -- "$LOCK_DIR"
    done
    rm -rf -- "$LOCK_TMP"
    LOCK_TMP=""
    die "cannot acquire update lock"
}

run_apt() {
    local -a args=("$@")
    local rc=0
    set +e
    APT_OUTPUT=$(LC_ALL=C DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
        APT_LISTCHANGES_FRONTEND=none apt-get "${args[@]}" 2>&1)
    rc=$?
    set -e
    printf '%s\n' "$APT_OUTPUT" >>"$LOG_FILE"
    if [[ "$QUIET" -eq 0 ]]; then
        printf '%s\n' "$APT_OUTPUT" >&2
    fi
    return "$rc"
}

upgrade_summary() {
    printf '%s\n' "$APT_OUTPUT" | grep -E '^[0-9]+ upgraded,' | tail -n 1 || true
}

collect_failures() {
    printf '%s\n' "$APT_OUTPUT" \
        | grep -E '^(E:|dpkg: error|W: Failed to fetch|W: Some index files failed)' \
        | sort -u | head -n 20 || true
}

collect_restarts() {
    printf '%s\n' "$APT_OUTPUT" \
        | grep -iE 'restarting (the following )?services|needrestart' \
        | head -n 5 || true
}

reboot_required() {
    [[ -f "$MXB_REBOOT_MARKER" ]]
}

reboot_packages() {
    local file
    for file in "$MXB_REBOOT_PKGS" "$MXB_REBOOT_MARKER.pkgs"; do
        if [[ -r "$file" ]]; then
            sort -u "$file" | head -n 30
            return 0
        fi
    done
    return 0
}

write_state() {
    local status=$1 summary=$2 failures=$3 reboot=$4 packages=$5 restarts=$6 duration_ms=$7
    local now tmp
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    tmp="$STATE_FILE.tmp.$$"
    jq -n \
        --arg version "$VERSION" \
        --arg now "$now" \
        --arg status "$status" \
        --arg summary "$summary" \
        --arg failures "$failures" \
        --argjson reboot "$reboot" \
        --arg packages "$packages" \
        --arg restarts "$restarts" \
        --argjson duration "$duration_ms" \
        --argjson dry_run "$DRY_RUN" \
        '{
            schema_version: 1,
            script_version: $version,
            last_run_at: $now,
            status: $status,
            summary: $summary,
            failures: ($failures | split("\n") | map(select(length > 0))),
            reboot_required: ($reboot == 1),
            reboot_packages: ($packages | split("\n") | map(select(length > 0))),
            service_restarts: ($restarts | split("\n") | map(select(length > 0))),
            duration_ms: $duration,
            dry_run: ($dry_run == 1)
        }' >"$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

main() {
    parse_args "$@"
    require_root
    mkdir -p "$MXB_LOG_DIR"
    acquire_lock

    local start end duration=0 failures summary="" restarts="" status="ok"
    local reboot=0 packages=""
    start=$(date +%s)

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "simulating an Ubuntu package upgrade (dry run)"
        run_apt -s -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef \
            --with-new-pkgs upgrade || true
    else
        log "starting Ubuntu package update"
        if ! run_apt update; then
            status="failed"
        elif ! run_apt -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef \
            -o APT::Get::Show-User-Simulation-Note=false --with-new-pkgs upgrade; then
            status="failed"
        fi
    fi

    summary=$(upgrade_summary)
    failures=$(collect_failures)
    restarts=$(collect_restarts)
    [[ -n "$failures" ]] && status="failed"

    if reboot_required; then
        reboot=1
        packages=$(reboot_packages)
    fi

    end=$(date +%s)
    (( end >= start )) && duration=$(( (end - start) * 1000 ))

    write_state "$status" "$summary" "$failures" "$reboot" "$packages" "$restarts" "$duration"

    if [[ "$status" == "failed" ]]; then
        log "package update completed with failures"
        [[ -n "$failures" ]] && printf '%s\n' "$failures" >&2
        [[ "$QUIET" -eq 1 ]] || printf 'update failed; see %s\n' "$LOG_FILE" >&2
        exit 1
    fi

    log "package update complete${summary:+ ($summary)}"
    if [[ "$reboot" -eq 1 ]]; then
        log "WARN: a reboot is required to complete the update; it was not performed automatically"
        [[ "$QUIET" -eq 1 ]] || printf 'reboot required (not performed automatically)\n' >&2
    fi
    exit 0
}

main "$@"
