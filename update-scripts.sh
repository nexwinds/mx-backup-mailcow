#!/usr/bin/env bash
#
# update-scripts.sh - install or update mx-backup-mailcow from GitHub Releases
#
# Part of mx-backup-mailcow. Standalone script: no shared libraries.
#
# Uses only published stable releases from the public repository, without any
# GitHub authentication token. Downloads are verified against SHA-256
# manifests before anything is replaced. Server configuration, credentials,
# Postfix maps, queues and logs are never touched.
#
set -Eeuo pipefail

SCRIPT_NAME="update-scripts"
REPO="nexwinds/mx-backup-mailcow"
GH_API="https://api.github.com/repos/${REPO}/releases"
GH_DL="https://github.com/${REPO}/releases/download"
PROG_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MAX_APP_BACKUPS=5

: "${MXB_INSTALL_DIR:=/opt/mx-backup-mailcow}"
: "${MXB_BIN_DIR:=/usr/local/sbin}"
: "${MXB_BACKUP_DIR:=/var/backups/mx-backup-mailcow}"
: "${MXB_STATE_DIR:=/var/lib/mailcow-backup-mx}"
: "${MXB_LOG_DIR:=/var/log/mailcow-backup-mx}"
: "${MXB_SYSTEMD_DIR:=/etc/systemd/system}"

LOG_FILE="$MXB_LOG_DIR/update-scripts.log"
STATE_FILE="$MXB_STATE_DIR/state/update-scripts-state.json"
RUN_DIR="$MXB_STATE_DIR/run"
LOCK_DIR="$RUN_DIR/scripts-update.lock"

ACTION="update"
WANT_VERSION="latest"
ROLLBACK_TARGET=""
CHECK_ONLY=0
LIST_ONLY=0
ASSUME_YES=0
FORCE=0
DRY_RUN=0
QUIET=0
VERIFY_INSTALL=""

WORK_DIR=""
NEW_ROOT=""
STAGING=""
LOCK_HELD=0
LOCK_TMP=""

VERSION="0.0.0-dev"
for version_file in "$PROG_DIR/../VERSION" "$PROG_DIR/VERSION" "$MXB_INSTALL_DIR/VERSION"; do
    [[ -r "$version_file" ]] || continue
    VERSION=$(<"$version_file")
    VERSION=${VERSION//[[:space:]]/}
    [[ -n "$VERSION" ]] && break
done
[[ -n "$VERSION" ]] || VERSION="0.0.0-dev"

usage() {
    cat <<'EOF'
Usage: update-scripts.sh [OPTIONS]

Install or update the mx-backup-mailcow application scripts from GitHub
Releases. Only published stable releases are used. No authentication token is
required.

Options:
  --check                 Compare the installed version with the latest release
  --list                  List the ten most recent releases
  --release VERSION       Install a specific version (e.g. 1.2.3)
  --rollback [VERSION]    Restore the most recent (or a specific) backup
  --dry-run               Download and verify, but do not install
  --yes                   Do not ask for confirmation
  --force                 Reinstall even when unchanged; allow downgrades
  --quiet                 Only write to the log file
  -h, --help              Show this help
  -V, --version           Show script version

Exit status: 0 success, 1 failure, 2 usage error.
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
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf -- "$WORK_DIR" 2>/dev/null || true
    [[ -n "$STAGING" && -d "$STAGING" ]] && rm -rf -- "$STAGING" 2>/dev/null || true
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
            --check) CHECK_ONLY=1 ;;
            --list) LIST_ONLY=1 ;;
            --release) WANT_VERSION=${2:?--release requires a version}; shift ;;
            --rollback)
                ACTION="rollback"
                if [[ ${2:-} != "" && ${2:-} != -* ]]; then
                    ROLLBACK_TARGET=$2
                    shift
                fi
                ;;
            --dry-run) DRY_RUN=1 ;;
            --yes|-y) ASSUME_YES=1 ;;
            --force) FORCE=1 ;;
            --quiet) QUIET=1 ;;
            --verify-install) VERIFY_INSTALL=${2:?--verify-install requires a version}; shift ;;
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
    LOCK_TMP="$RUN_DIR/.scripts-update.lock.$$"
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
            die "another application update is running (pid $pid)"
        fi
        log "WARN: removing stale application update lock"
        rm -rf -- "$LOCK_DIR"
    done
    rm -rf -- "$LOCK_TMP"
    LOCK_TMP=""
    die "cannot acquire update lock"
}

installed_version() {
    if [[ -r "$MXB_INSTALL_DIR/VERSION" ]]; then
        local v
        v=$(<"$MXB_INSTALL_DIR/VERSION")
        printf '%s' "${v//[[:space:]]/}"
    else
        printf '0.0.0'
    fi
}

is_semver() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

version_lt() {
    local a=$1 b=$2
    [[ "$a" == "$b" ]] && return 1
    [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1)" == "$a" ]]
}

github_json() {
    local url=$1 out=$2 code rc=0
    code=$(curl --silent --show-error --proto '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 60 --retry 2 --retry-delay 2 \
        --header 'Accept: application/vnd.github+json' \
        --header "User-Agent: mx-backup-mailcow/${VERSION}" \
        --output "$out" --write-out '%{http_code}' "$url") || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        die "cannot reach the GitHub API (curl exit $rc)"
    fi
    case "$code" in
        200) return 0 ;;
        403)
            die "GitHub API rate limit reached; retry later or use --release VERSION (no token is used by design)"
            ;;
        404)
            die "release not found: $url"
            ;;
        *) die "GitHub API returned HTTP $code" ;;
    esac
}

download_file() {
    local url=$1 out=$2
    curl --silent --show-error --fail \
        --proto '=https' --proto-redir '=https' --location --max-redirs 5 \
        --tlsv1.2 \
        --connect-timeout 15 --max-time 180 --retry 2 --retry-delay 2 \
        --header "User-Agent: mx-backup-mailcow/${VERSION}" \
        --output "$out" "$url" \
        || die "download failed: $url"
}

latest_release_version() {
    local json="$WORK_DIR/latest.json" tag
    github_json "$GH_API/latest" "$json"
    tag=$(jq -r '.tag_name // empty' "$json" 2>/dev/null)
    [[ -n "$tag" ]] || die "could not determine the latest release"
    printf '%s' "${tag#v}"
}

release_version_for_tag() {
    local ver=$1 json="$WORK_DIR/release-$1.json" tag
    github_json "$GH_API/tags/v${ver}" "$json"
    tag=$(jq -r '.tag_name // empty' "$json" 2>/dev/null)
    [[ -n "$tag" ]] || die "release v$ver not found"
    printf '%s' "${tag#v}"
}

list_releases() {
    local json="$WORK_DIR/list.json"
    github_json "$GH_API?per_page=10" "$json"
    jq -r '.[] | "\(.tag_name)\t\(.published_at // "")"' "$json" 2>/dev/null \
        || die "could not parse the release list"
}

check_archive_paths() {
    local archive=$1
    if tar -tzf "$archive" | grep -Eq '(^/)|(^|/)\.\.(/|$)'; then
        die "release archive contains unsafe paths"
    fi
}

verify_extracted_tree() {
    local root=$1 ver=$2 script
    [[ -d "$root" ]] || die "release archive has an unexpected layout"
    [[ -f "$root/VERSION" ]] || die "release is missing VERSION"
    [[ "$(<"$root/VERSION")" == "$ver" ]] \
        || die "release VERSION does not match the requested version"
    [[ -f "$root/SHA256SUMS" ]] || die "release is missing the SHA256SUMS manifest"
    ( cd "$root" && sha256sum -c SHA256SUMS --quiet ) \
        || die "release file checksums do not match the manifest"
    for script in install.sh sync-mailcow.sh update.sh diagnose.sh update-scripts.sh; do
        [[ -f "$root/bin/$script" ]] || die "release is missing bin/$script"
        bash -n "$root/bin/$script" || die "release contains an invalid script: $script"
    done
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck -S error -x "$root"/bin/*.sh >/dev/null 2>&1 \
            || die "release scripts fail ShellCheck validation"
    fi
    return 0
}

download_release() {
    local ver=$1 archive sums expected actual root
    archive="$WORK_DIR/mx-backup-mailcow-$ver.tar.gz"
    sums="$WORK_DIR/SHA256SUMS"

    download_file "$GH_DL/v$ver/SHA256SUMS" "$sums"
    download_file "$GH_DL/v$ver/mx-backup-mailcow-$ver.tar.gz" "$archive"

    expected=$(awk -v f="mx-backup-mailcow-$ver.tar.gz" '$2==f || $2=="*"f {print $1; exit}' "$sums")
    [[ -n "$expected" ]] || die "checksum manifest does not list the release archive"
    actual=$(sha256sum "$archive" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] \
        || die "release checksum mismatch (expected $expected, got $actual)"

    check_archive_paths "$archive"
    tar -xzf "$archive" -C "$WORK_DIR" --no-same-owner --no-same-permissions
    root="$WORK_DIR/mx-backup-mailcow-$ver"
    verify_extracted_tree "$root" "$ver"
    NEW_ROOT="$root"
    log "release v$ver downloaded and verified"
}

prune_backups() {
    local -a old=()
    mapfile -t old < <(find "$MXB_BACKUP_DIR" -maxdepth 1 -type d -name 'app-*' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | awk -v keep="$MAX_APP_BACKUPS" 'NR > keep {print $2}')
    if (( ${#old[@]} > 0 )); then
        rm -rf -- "${old[@]}"
    fi
}

backup_application() {
    local label=$1 dir
    dir="$MXB_BACKUP_DIR/app-$(date -u '+%Y%m%dT%H%M%SZ')-${label}"
    mkdir -p "$MXB_BACKUP_DIR"
    cp -a "$MXB_INSTALL_DIR" "$dir" || die "cannot back up the current application"
    prune_backups
    printf '%s' "$dir"
}

ensure_symlinks() {
    ln -sfn "$MXB_INSTALL_DIR/bin/sync-mailcow.sh" "$MXB_BIN_DIR/sync-mailcow"
    ln -sfn "$MXB_INSTALL_DIR/bin/update.sh" "$MXB_BIN_DIR/mx-update"
    ln -sfn "$MXB_INSTALL_DIR/bin/diagnose.sh" "$MXB_BIN_DIR/mx-diagnose"
    ln -sfn "$MXB_INSTALL_DIR/bin/update-scripts.sh" "$MXB_BIN_DIR/mx-update-scripts"
}

install_units() {
    local unit src dest reloaded=0
    for unit in mailcow-sync.service mailcow-sync.timer; do
        src="$MXB_INSTALL_DIR/systemd/$unit"
        dest="$MXB_SYSTEMD_DIR/$unit"
        [[ -f "$src" ]] || continue
        if [[ ! -f "$dest" ]] || ! cmp -s "$src" "$dest"; then
            mkdir -p "$MXB_SYSTEMD_DIR"
            install -m 0644 "$src" "$dest"
            reloaded=1
        fi
    done
    if [[ "$reloaded" -eq 1 ]]; then
        systemctl daemon-reload || log "WARN: systemctl daemon-reload failed"
    fi
    if ! systemctl is-enabled --quiet mailcow-sync.timer 2>/dev/null; then
        systemctl enable mailcow-sync.timer || log "WARN: could not enable mailcow-sync.timer"
    fi
    [[ "$QUIET" -eq 1 ]] || printf 'units_reloaded=%s\n' "$reloaded"
    return 0
}

write_state() {
    local installed=$1 previous=$2 action=$3 source=$4 now tmp
    now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    tmp="$STATE_FILE.tmp.$$"
    mkdir -p "$MXB_STATE_DIR/state"
    jq -n \
        --arg now "$now" \
        --arg installed "$installed" \
        --arg previous "$previous" \
        --arg action "$action" \
        --arg source "$source" \
        --arg tool "$VERSION" \
        '{
            schema_version: 1,
            tool_version: $tool,
            updated_at: $now,
            installed_version: $installed,
            previous_version: $previous,
            action: $action,
            source: $source
        }' >"$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

confirm_update() {
    local from=$1 to=$2
    [[ "$ASSUME_YES" -eq 1 ]] && return 0
    [[ "$NON_INTERACTIVE" -eq 1 ]] && return 0
    local answer=""
    printf 'Update mx-backup-mailcow %s -> %s? [y/N] ' "$from" "$to"
    IFS= read -r answer || true
    [[ "$answer" =~ ^[Yy]$ ]] || die "update cancelled"
}

NON_INTERACTIVE=0
[[ -t 0 ]] || NON_INTERACTIVE=1

do_verify_install() {
    local expected=$1 installed
    installed=$(installed_version)
    [[ "$installed" == "$expected" ]] \
        || die "post-update verification failed: installed $installed, expected $expected"
    ( cd "$MXB_INSTALL_DIR" && sha256sum -c SHA256SUMS --quiet ) \
        || die "post-update verification failed: file checksums do not match"
    ensure_symlinks
    write_state "$installed" "$installed" "verify" "local"
    log "post-update verification passed for version $installed"
    exit 0
}

do_check() {
    local installed latest
    installed=$(installed_version)
    latest=$(latest_release_version)
    if [[ "$installed" == "$latest" ]]; then
        printf 'installed %s\nlatest %s\nstatus up-to-date\n' "$installed" "$latest"
    else
        printf 'installed %s\nlatest %s\nstatus update-available\n' "$installed" "$latest"
    fi
    exit 0
}

do_list() {
    list_releases
    exit 0
}

do_rollback() {
    local target=$1 dir="" inst
    if [[ -n "$target" ]]; then
        if [[ -d "$target" ]]; then
            dir=$target
        else
            dir=$(find "$MXB_BACKUP_DIR" -maxdepth 1 -type d -name "app-*-${target}" -printf '%T@ %p\n' 2>/dev/null \
                | sort -rn | awk 'NR==1 {print $2}')
        fi
    else
        dir=$(find "$MXB_BACKUP_DIR" -maxdepth 1 -type d -name 'app-*' -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | awk 'NR==1 {print $2}')
    fi
    [[ -n "$dir" && -d "$dir" ]] || die "no application backup found${target:+ for '$target'}"
    [[ -f "$dir/VERSION" ]] || die "backup is incomplete: $dir"

    inst=$(installed_version)
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf 'would roll back %s to %s (%s)\n' "$inst" "$(<"$dir/VERSION")" "$dir"
        exit 0
    fi

    confirm_update "$inst" "backup $(basename "$dir")"
    backup_application "pre-rollback-${inst}" >/dev/null || true
    STAGING="$MXB_INSTALL_DIR.stage.$$"
    rm -rf -- "$STAGING"
    cp -a "$dir" "$STAGING"
    replace_install_dir "$STAGING"
    STAGING=""
    write_state "$(installed_version)" "$inst" "rollback" "backup"
    log "rolled back to $(basename "$dir")"
    exit 0
}

replace_install_dir() {
    local newdir=$1 olddir
    olddir="$MXB_INSTALL_DIR.old.$$"
    [[ -d "$MXB_INSTALL_DIR" ]] || die "application is not installed in $MXB_INSTALL_DIR"
    rm -rf -- "$olddir"
    mv "$MXB_INSTALL_DIR" "$olddir"
    if ! mv "$newdir" "$MXB_INSTALL_DIR"; then
        mv "$olddir" "$MXB_INSTALL_DIR" || true
        die "failed to install the new application directory"
    fi
    rm -rf -- "$olddir"
    ensure_symlinks
    install_units >/dev/null || true
}

do_update() {
    local installed target ver
    installed=$(installed_version)

    if [[ "$WANT_VERSION" == "latest" ]]; then
        target=$(latest_release_version)
    else
        is_semver "${WANT_VERSION#v}" || die "invalid version: $WANT_VERSION"
        target=$(release_version_for_tag "${WANT_VERSION#v}")
    fi
    is_semver "$target" || die "invalid release version: $target"

    if [[ "$installed" == "$target" && "$FORCE" -eq 0 ]]; then
        log "already at version $installed; nothing to do"
        [[ "$QUIET" -eq 1 ]] || printf 'installed %s is up to date\n' "$installed"
        exit 0
    fi
    if ! version_lt "$installed" "$target" && [[ "$FORCE" -eq 0 ]]; then
        log "installed version $installed is newer than $target; use --force to downgrade"
        exit 0
    fi

    log "installing version $target (current: $installed)"
    download_release "$target"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf 'would install version %s (current %s)\n' "$target" "$installed"
        exit 0
    fi
    confirm_update "$installed" "$target"

    local backup
    backup=$(backup_application "$installed")
    log "current application backed up to $backup"

    STAGING="$MXB_INSTALL_DIR.stage.$$"
    rm -rf -- "$STAGING"
    mv "$NEW_ROOT" "$STAGING"
    if ! replace_install_dir "$STAGING"; then
        [[ -d "$backup" ]] && { rm -rf -- "$MXB_INSTALL_DIR"; cp -a "$backup" "$MXB_INSTALL_DIR"; }
        die "installation failed; previous version restored"
    fi
    STAGING=""

    # Prove that the new self-updating script works before reporting success.
    if ! "$MXB_INSTALL_DIR/bin/update-scripts.sh" --verify-install "$target" --quiet; then
        log "ERROR: new version failed verification; restoring $installed"
        rm -rf -- "$MXB_INSTALL_DIR"
        cp -a "$backup" "$MXB_INSTALL_DIR"
        ensure_symlinks
        install_units >/dev/null 2>&1 || true
        write_state "$installed" "$target" "rollback" "github"
        die "update aborted and rolled back to $installed"
    fi

    write_state "$target" "$installed" "update" "github"
    log "application updated from $installed to $target"
    [[ "$QUIET" -eq 1 ]] || printf 'updated %s -> %s\n' "$installed" "$target"
    exit 0
}

main() {
    parse_args "$@"
    require_root
    unset GITHUB_TOKEN GH_TOKEN 2>/dev/null || true
    mkdir -p "$MXB_LOG_DIR"

    if [[ -n "$VERIFY_INSTALL" ]]; then
        do_verify_install "$VERIFY_INSTALL"
    fi

    acquire_lock
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mx-update-scripts.XXXXXX")

    case "$ACTION" in
        rollback) do_rollback "$ROLLBACK_TARGET" ;;
        update)
            if [[ "$CHECK_ONLY" -eq 1 ]]; then do_check; fi
            if [[ "$LIST_ONLY" -eq 1 ]]; then do_list; fi
            do_update
            ;;
    esac
}

main "$@"
