#!/usr/bin/env bash
#
# install.sh - provision an Ubuntu 24.04 server as a Mailcow Backup MX
#
# Part of mx-backup-mailcow. Standalone script: no shared libraries.
#
# The installer bootstraps the latest stable GitHub release (or a local
# directory), installs Postfix and its dependencies, writes the Postfix
# configuration, installs the systemd timer and performs an initial sync.
# It is idempotent and never discards existing credentials or configuration.
#
set -Eeuo pipefail

SCRIPT_NAME="install"
REPO="nexwinds/mx-backup-mailcow"
GH_API="https://api.github.com/repos/${REPO}/releases"
GH_DL="https://github.com/${REPO}/releases/download"
RE_DOMAIN='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9]([a-z0-9-]{0,57}[a-z0-9])?)$'
PROG_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

: "${MXB_ETC:=/etc/mailcow-backup-mx}"
: "${MXB_CONFIG_FILE:=$MXB_ETC/config}"
: "${MXB_MAPS_DIR:=/etc/postfix/mailcow-backup-mx}"
: "${MXB_STATE_DIR:=/var/lib/mailcow-backup-mx}"
: "${MXB_LOG_DIR:=/var/log/mailcow-backup-mx}"
: "${MXB_BACKUP_DIR:=/var/backups/mx-backup-mailcow}"
: "${MXB_INSTALL_DIR:=/opt/mx-backup-mailcow}"
: "${MXB_BIN_DIR:=/usr/local/sbin}"
: "${MXB_OS_RELEASE:=/etc/os-release}"
: "${MXB_SYSTEMD_DIR:=/etc/systemd/system}"
: "${MXB_LOGROTATE_DIR:=/etc/logrotate.d}"
: "${MXB_POSTFIX_ETC:=/etc/postfix}"
: "${MXB_SSH_DIR:=/etc/ssh}"
: "${MXB_CA_BUNDLE:=/etc/ssl/certs/ca-certificates.crt}"

MANAGED_KEYS=(
    MAILCOW_HOST
    MAILCOW_API_KEY
    MAILCOW_API_CA_FILE
    MAILCOW_PRIMARY_IP
    MAILCOW_PRIMARY_PORT
    SMTP_TLS_MODE
    SMTP_TLS_MATCH_HOSTNAME
    EXCLUDE_DOMAINS
    RELAX_AFTER_DAYS
    QUEUE_LIFETIME
    MESSAGE_SIZE_LIMIT
)

NON_INTERACTIVE=0
ASSUME_YES=0
SKIP_UPGRADE=0
SKIP_INITIAL_SYNC=0
NO_FIREWALL=0
LOCAL_DIR=""
WANT_VERSION="latest"
INSTALLER_SHA256=""
API_KEY_STDIN=0
FORCE=0
CONFIG_INPUT=""

ARG_HOST=""
ARG_IP=""
ARG_KEY=""
ARG_CA=""
ARG_TLS_MODE=""
ARG_TLS_MATCH=""

WORK_DIR=""
RELEASE_ROOT=""
RESOLVED_VERSION=""

VERSION="0.0.0-dev"
for version_file in "$PROG_DIR/../VERSION" "$PROG_DIR/VERSION"; do
    [[ -r "$version_file" ]] || continue
    VERSION=$(<"$version_file")
    VERSION=${VERSION//[[:space:]]/}
    [[ -n "$VERSION" ]] && break
done
[[ -n "$VERSION" ]] || VERSION="0.0.0-dev"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Provision this Ubuntu 24.04 server as a Mailcow Backup MX.

Connection options:
  --mailcow-host HOST       Mailcow hostname, e.g. mail.example.com
  --primary-ip IP           Primary Mailcow IP address
  --api-key KEY             Mailcow read-only API key (prefer --api-key-stdin)
  --api-key-stdin           Read the API key from standard input
  --ca-file PATH            Private CA bundle used to verify the Mailcow API
  --smtp-tls-mode MODE      may (default) or secure
  --tls-match HOSTNAME      Certificate hostname for SMTP_TLS_MODE=secure

Source options:
  --release VERSION         Install a specific release (default: latest)
  --local-dir DIR           Install from a local release/checkout instead of GitHub
  --sha256 HEX              Verify this installer file before running

Behaviour:
  --non-interactive         Never prompt; all required values must be provided
  --yes                     Assume yes for confirmations
  --config FILE             Read configuration values from FILE
  --skip-upgrade            Do not upgrade existing Ubuntu packages
  --skip-initial-sync       Do not run the initial synchronization
  --no-firewall             Do not configure UFW
  --force                   Proceed on warnings that are otherwise fatal
  -h, --help                Show this help
  -V, --version             Show installer version
EOF
}

log() {
    local line
    line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') [$SCRIPT_NAME] $*"
    printf '%s\n' "$line" >&2
    if [[ -d "$MXB_LOG_DIR" ]]; then
        printf '%s\n' "$line" >>"$MXB_LOG_DIR/install.log" 2>/dev/null || true
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
    log "ERROR: installation failed at line ${line} (exit ${rc})"
    exit "$rc"
}

cleanup() {
    local rc=$?
    trap - EXIT
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf -- "$WORK_DIR" 2>/dev/null || true
    exit "$rc"
}

trap 'on_error $LINENO' ERR
trap cleanup EXIT

require_root() {
    [[ "${MXB_SKIP_ROOT_CHECK:-0}" == "1" ]] && return 0
    [[ "$(id -u)" -eq 0 ]] || die "must be run as root (use sudo)"
}

check_os() {
    [[ -r "$MXB_OS_RELEASE" ]] || die "cannot read $MXB_OS_RELEASE"
    local id="" version_id=""
    # shellcheck disable=SC1090
    eval "$(grep -E '^(ID|VERSION_ID)=' "$MXB_OS_RELEASE")"
    id=${ID:-}
    version_id=${VERSION_ID:-}
    if [[ "$id" != "ubuntu" || "$version_id" != "24.04" ]]; then
        if [[ "$FORCE" -eq 1 ]]; then
            warn "expected Ubuntu 24.04 LTS, found ${id:-unknown} ${version_id:-unknown}; continuing due to --force"
        else
            die "this installer supports Ubuntu 24.04 LTS only (found ${id:-unknown} ${version_id:-unknown})"
        fi
    fi
}

check_hostname() {
    local fqdn
    fqdn=$(hostname -f 2>/dev/null || true)
    [[ -z "$fqdn" ]] && fqdn=$(hostname 2>/dev/null || true)
    if [[ "$fqdn" != *.* ]]; then
        warn "the server hostname '$fqdn' is not fully qualified; set a FQDN with 'hostnamectl set-hostname'"
    fi
    BACKUP_MX_HOSTNAME=$fqdn
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive) NON_INTERACTIVE=1 ;;
            --yes|-y) ASSUME_YES=1 ;;
            --skip-upgrade) SKIP_UPGRADE=1 ;;
            --skip-initial-sync) SKIP_INITIAL_SYNC=1 ;;
            --no-firewall) NO_FIREWALL=1 ;;
            --force) FORCE=1 ;;
            --api-key-stdin) API_KEY_STDIN=1 ;;
            --local-dir) LOCAL_DIR=${2:?--local-dir requires a directory}; shift ;;
            --release) WANT_VERSION=${2:?--release requires a value}; shift ;;
            --sha256) INSTALLER_SHA256=${2:?--sha256 requires a value}; shift ;;
            --config) CONFIG_INPUT=${2:?--config requires a file}; shift ;;
            --mailcow-host) ARG_HOST=${2:?}; shift ;;
            --primary-ip|--mailcow-primary-ip) ARG_IP=${2:?}; shift ;;
            --api-key) ARG_KEY=${2:?}; shift ;;
            --ca-file) ARG_CA=${2:?}; shift ;;
            --smtp-tls-mode) ARG_TLS_MODE=${2:?}; shift ;;
            --tls-match) ARG_TLS_MATCH=${2:?}; shift ;;
            -h|--help) usage; exit 0 ;;
            -V|--version) printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
            *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
load_existing_config() {
    MAILCOW_HOST=""
    MAILCOW_API_KEY=""
    MAILCOW_API_CA_FILE=""
    MAILCOW_PRIMARY_IP=""
    MAILCOW_PRIMARY_PORT="25"
    SMTP_TLS_MODE="may"
    SMTP_TLS_MATCH_HOSTNAME=""
    # shellcheck disable=SC2034  # persisted to the configuration file
    EXCLUDE_DOMAINS=""
    RELAX_AFTER_DAYS="7"
    QUEUE_LIFETIME="7d"
    MESSAGE_SIZE_LIMIT="104857600"

    if [[ -r "$MXB_CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        . "$MXB_CONFIG_FILE"
    fi
    if [[ -n "${CONFIG_INPUT:-}" ]]; then
        [[ -r "$CONFIG_INPUT" ]] || die "cannot read --config file: $CONFIG_INPUT"
        # shellcheck disable=SC1090
        . "$CONFIG_INPUT"
    fi
    if [[ "$API_KEY_STDIN" -eq 1 ]]; then
        IFS= read -r MAILCOW_API_KEY || die "no API key received on standard input"
    fi

    # Command-line values have the highest precedence.
    [[ -n "$ARG_HOST" ]] && MAILCOW_HOST=$ARG_HOST
    [[ -n "$ARG_IP" ]] && MAILCOW_PRIMARY_IP=$ARG_IP
    [[ -n "$ARG_KEY" ]] && MAILCOW_API_KEY=$ARG_KEY
    [[ -n "$ARG_CA" ]] && MAILCOW_API_CA_FILE=$ARG_CA
    [[ -n "$ARG_TLS_MODE" ]] && SMTP_TLS_MODE=$ARG_TLS_MODE
    [[ -n "$ARG_TLS_MATCH" ]] && SMTP_TLS_MATCH_HOSTNAME=$ARG_TLS_MATCH

    MAILCOW_HOST=${MAILCOW_HOST,,}
    MAILCOW_HOST=${MAILCOW_HOST%.}
    SMTP_TLS_MATCH_HOSTNAME=${SMTP_TLS_MATCH_HOSTNAME,,}
}

prompt() {
    local var=$1 label=$2 secret=${3:-0} value
    local current=${!var:-}
    if [[ "$secret" -eq 1 ]]; then
        printf '%s' "$label"
        [[ -n "$current" ]] && printf ' [keep existing]'
        printf ': '
        IFS= read -rs value || true
        printf '\n'
    else
        printf '%s' "$label"
        [[ -n "$current" ]] && printf ' [%s]' "$current"
        printf ': '
        IFS= read -r value || true
    fi
    if [[ -n "$value" ]]; then
        printf -v "$var" '%s' "$value"
    fi
}

interactive_config() {
    [[ "$NON_INTERACTIVE" -eq 1 ]] && return 0
    printf '\nMailcow Backup MX configuration\n'
    printf 'Press Enter to accept the value in brackets.\n\n'
    prompt MAILCOW_HOST "Mailcow hostname (API endpoint)"
    prompt MAILCOW_PRIMARY_IP "Primary Mailcow IP address"
    prompt MAILCOW_API_KEY "Read-only API key" 1
    prompt MAILCOW_API_CA_FILE "Private CA file for the API (optional)"
    prompt SMTP_TLS_MODE "SMTP TLS mode for the primary (may/secure)"
}

validate_config() {
    [[ -n "$MAILCOW_HOST" ]] || die "MAILCOW_HOST is required (use --mailcow-host or --non-interactive with --config)"
    [[ -n "$MAILCOW_PRIMARY_IP" ]] || die "MAILCOW_PRIMARY_IP is required (use --primary-ip or --non-interactive with --config)"
    [[ -n "$MAILCOW_API_KEY" ]] || die "MAILCOW_API_KEY is required (use --api-key-stdin or --config)"

    [[ "$MAILCOW_HOST" =~ $RE_DOMAIN ]] \
        || die "MAILCOW_HOST is not a valid hostname: $MAILCOW_HOST"
    [[ "$MAILCOW_API_KEY" =~ ^[A-Za-z0-9-]+$ ]] || die "MAILCOW_API_KEY contains unexpected characters"
    (( ${#MAILCOW_API_KEY} >= 16 )) || die "MAILCOW_API_KEY is too short"

    local o
    if [[ "$MAILCOW_PRIMARY_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        for o in ${MAILCOW_PRIMARY_IP//./ }; do
            (( o >= 0 && o <= 255 )) || die "MAILCOW_PRIMARY_IP is invalid"
        done
    elif [[ "$MAILCOW_PRIMARY_IP" == *:* && "$MAILCOW_PRIMARY_IP" =~ ^[0-9a-fA-F:]+$ ]]; then
        :
    else
        die "MAILCOW_PRIMARY_IP is not a valid IP address: $MAILCOW_PRIMARY_IP"
    fi

    [[ "$MAILCOW_PRIMARY_PORT" =~ ^[0-9]+$ ]] \
        || die "MAILCOW_PRIMARY_PORT must be numeric"
    (( MAILCOW_PRIMARY_PORT >= 1 && MAILCOW_PRIMARY_PORT <= 65535 )) \
        || die "MAILCOW_PRIMARY_PORT is out of range"

    case "$SMTP_TLS_MODE" in
        may) ;;
        secure)
            [[ "$SMTP_TLS_MATCH_HOSTNAME" =~ $RE_DOMAIN ]] \
                || die "SMTP_TLS_MODE=secure requires --tls-match HOSTNAME"
            ;;
        *) die "SMTP_TLS_MODE must be 'may' or 'secure'" ;;
    esac

    [[ "$RELAX_AFTER_DAYS" =~ ^[0-9]+$ ]] || die "RELAX_AFTER_DAYS must be an integer"
    [[ "$QUEUE_LIFETIME" =~ ^[0-9]+[smhdw]$ ]] || die "QUEUE_LIFETIME must look like 7d"
    [[ "$MESSAGE_SIZE_LIMIT" =~ ^[0-9]+$ ]] || die "MESSAGE_SIZE_LIMIT must be a byte count"

    if [[ -n "$MAILCOW_API_CA_FILE" && ! -r "$MAILCOW_API_CA_FILE" ]]; then
        die "MAILCOW_API_CA_FILE is not readable: $MAILCOW_API_CA_FILE"
    fi
}

write_config() {
    local key line tmp matched done_keys=" "
    local -a keys=("${MANAGED_KEYS[@]}")
    tmp="$MXB_CONFIG_FILE.tmp.$$"
    umask 077
    : >"$tmp"
    if [[ -f "$MXB_CONFIG_FILE" ]]; then
        while IFS= read -r line; do
            matched=0
            for key in "${keys[@]}"; do
                if [[ $line =~ ^[[:space:]]*${key}= ]]; then
                    printf '%s=%q\n' "$key" "${!key-}" >>"$tmp"
                    done_keys+="$key "
                    matched=1
                    break
                fi
            done
            if [[ "$matched" -eq 0 ]]; then
                printf '%s\n' "$line" >>"$tmp"
            fi
        done <"$MXB_CONFIG_FILE"
    else
        {
            printf '# mx-backup-mailcow configuration\n'
            printf '# Managed keys are rewritten by install.sh; other lines are preserved.\n'
        } >>"$tmp"
    fi
    for key in "${keys[@]}"; do
        [[ $done_keys == *" $key "* ]] && continue
        printf '%s=%q\n' "$key" "${!key-}" >>"$tmp"
    done
    chmod 0600 "$tmp"
    [[ "$(id -u)" -eq 0 ]] && chown root:root "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$MXB_CONFIG_FILE"
    chmod 0750 "$MXB_ETC"
}

# ---------------------------------------------------------------------------
# Release acquisition
# ---------------------------------------------------------------------------
is_semver() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

http_get() {
    local url=$1 out=$2
    curl --silent --show-error --fail \
        --proto '=https' --proto-redir '=https' --location --max-redirs 5 \
        --tlsv1.2 \
        --connect-timeout 15 --max-time 120 --retry 2 --retry-delay 2 \
        --header "User-Agent: mx-backup-mailcow/${VERSION}" \
        --output "$out" "$url"
}

verify_installer() {
    [[ -n "$INSTALLER_SHA256" ]] || return 0
    local actual
    [[ -r "${BASH_SOURCE[0]}" ]] || die "--sha256 given but the installer file is not readable"
    actual=$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')
    [[ "$actual" == "$INSTALLER_SHA256" ]] \
        || die "installer checksum mismatch (expected $INSTALLER_SHA256, got $actual)"
    log "installer checksum verified"
}

resolve_version() {
    local api_json="$WORK_DIR/release.json" tag
    if [[ "$WANT_VERSION" == "latest" ]]; then
        http_get "$GH_API/latest" "$api_json" 2>/dev/null \
            || die "cannot reach the GitHub releases API (repository $REPO must have a published release); use --local-dir to install from local files"
        tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$api_json" | head -n 1)
        [[ -n "$tag" ]] || die "could not determine the latest release version"
        RESOLVED_VERSION=${tag#v}
    else
        RESOLVED_VERSION=${WANT_VERSION#v}
    fi
    is_semver "$RESOLVED_VERSION" || die "invalid version: $RESOLVED_VERSION"
}

check_archive_paths() {
    local archive=$1
    if tar -tzf "$archive" | grep -Eq '(^/)|(^|/)\.\.(/|$)'; then
        die "release archive contains unsafe paths"
    fi
}

fetch_release() {
    local ver="$RESOLVED_VERSION" archive sums expected actual root
    ver="v${RESOLVED_VERSION}"
    archive="$WORK_DIR/mx-backup-mailcow-${RESOLVED_VERSION}.tar.gz"
    sums="$WORK_DIR/SHA256SUMS"

    log "downloading release ${RESOLVED_VERSION} from GitHub"
    http_get "$GH_DL/$ver/SHA256SUMS" "$sums" \
        || die "cannot download the checksum manifest for $ver"
    http_get "$GH_DL/$ver/mx-backup-mailcow-${RESOLVED_VERSION}.tar.gz" "$archive" \
        || die "cannot download the release archive for $ver"

    expected=$(awk -v f="mx-backup-mailcow-${RESOLVED_VERSION}.tar.gz" '$2==f || $2=="*"f {print $1; exit}' "$sums")
    [[ -n "$expected" ]] || die "checksum manifest does not list the release archive"
    actual=$(sha256sum "$archive" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] \
        || die "release checksum mismatch (expected $expected, got $actual)"

    check_archive_paths "$archive"
    tar -xzf "$archive" -C "$WORK_DIR" --no-same-owner --no-same-permissions
    root="$WORK_DIR/mx-backup-mailcow-${RESOLVED_VERSION}"
    [[ -d "$root" ]] || die "release archive has an unexpected layout"

    [[ -f "$root/VERSION" ]] || die "release is missing VERSION"
    [[ "$(<"$root/VERSION")" == "$RESOLVED_VERSION" ]] \
        || die "release VERSION does not match the requested version"

    if [[ -f "$root/SHA256SUMS" ]]; then
        ( cd "$root" && sha256sum -c SHA256SUMS --quiet ) \
            || die "release file checksums do not match the manifest"
    fi

    local script
    for script in install.sh sync-mailcow.sh update.sh diagnose.sh update-scripts.sh; do
        [[ -f "$root/bin/$script" ]] || die "release is missing bin/$script"
        bash -n "$root/bin/$script" || die "release contains an invalid script: $script"
    done
    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck -S error -x "$root"/bin/*.sh >/dev/null 2>&1 \
            || warn "ShellCheck reported errors in the release; continuing"
    fi
    RELEASE_ROOT="$root"
    log "release ${RESOLVED_VERSION} verified"
}

prepare_local_tree() {
    local dir=$1 root
    [[ -d "$dir" ]] || die "--local-dir is not a directory: $dir"
    if [[ -f "$dir/bin/sync-mailcow.sh" ]]; then
        root="$dir"
    else
        [[ -f "$dir/sync-mailcow.sh" ]] || die "--local-dir contains neither bin/sync-mailcow.sh nor sync-mailcow.sh"
        root="$WORK_DIR/mx-backup-mailcow-$VERSION"
        mkdir -p "$root/bin" "$root/systemd" "$root/share/doc" "$root/config" "$root/logrotate"
        cp -f "$dir"/sync-mailcow.sh "$dir"/update.sh "$dir"/diagnose.sh "$dir"/update-scripts.sh "$dir"/install.sh "$root/bin/"
        cp -f "$dir/VERSION" "$root/VERSION" 2>/dev/null || printf '%s\n' "$VERSION" >"$root/VERSION"
        [[ -d "$dir/systemd" ]] && cp -f "$dir/systemd"/* "$root/systemd/" 2>/dev/null || true
        [[ -d "$dir/config" ]] && cp -f "$dir/config"/* "$root/config/" 2>/dev/null || true
        [[ -d "$dir/logrotate" ]] && cp -f "$dir/logrotate"/* "$root/logrotate/" 2>/dev/null || true
        [[ -f "$dir/README.md" ]] && cp -f "$dir/README.md" "$root/share/doc/"
        [[ -f "$dir/CHANGELOG.md" ]] && cp -f "$dir/CHANGELOG.md" "$root/share/doc/"
        [[ -f "$dir/LICENSE" ]] && cp -f "$dir/LICENSE" "$root/share/doc/"
        chmod 0755 "$root/bin"/*.sh
    fi
    RELEASE_ROOT="$root"
    if [[ -r "$root/VERSION" ]]; then
        RESOLVED_VERSION=$(<"$root/VERSION")
        RESOLVED_VERSION=${RESOLVED_VERSION//[[:space:]]/}
    else
        RESOLVED_VERSION=$VERSION
    fi
    local script
    for script in install.sh sync-mailcow.sh update.sh diagnose.sh update-scripts.sh; do
        [[ -f "$root/bin/$script" ]] || die "--local-dir is missing $script"
        bash -n "$root/bin/$script" || die "invalid script in --local-dir: $script"
    done
    log "using local release tree: $root"
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------
ensure_curl() {
    if command -v curl >/dev/null 2>&1 \
        && command -v sha256sum >/dev/null 2>&1 \
        && [[ -r "$MXB_CA_BUNDLE" ]]; then
        return 0
    fi
    log "installing curl and CA certificates"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates
}

apt_upgrade() {
    [[ "$SKIP_UPGRADE" -eq 1 ]] && { log "skipping Ubuntu package upgrade"; return 0; }
    log "updating and upgrading Ubuntu packages"
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    apt-get update
    apt-get -y \
        -o Dpkg::Options::=--force-confold \
        -o Dpkg::Options::=--force-confdef \
        -o APT::Get::Show-User-Simulation-Note=false \
        upgrade
}

install_packages() {
    log "installing Postfix and dependencies"
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    if ! dpkg-query -W -f='${Status}' postfix 2>/dev/null | grep -q "install ok installed"; then
        debconf-set-selections <<EOF
postfix postfix/main_mailer_type select No configuration
postfix postfix/mailname string ${BACKUP_MX_HOSTNAME:-localhost}
EOF
    fi
    apt-get -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef \
        install postfix curl jq ca-certificates ufw logrotate
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------
ensure_dir() {
    local mode=$1 path=$2
    mkdir -p "$path"
    chmod "$mode" "$path" 2>/dev/null || true
}

create_directories() {
    ensure_dir 0750 "$MXB_ETC"
    ensure_dir 0750 "$MXB_STATE_DIR"
    ensure_dir 0750 "$MXB_STATE_DIR/state"
    ensure_dir 0750 "$MXB_STATE_DIR/cache"
    ensure_dir 0750 "$MXB_STATE_DIR/run"
    ensure_dir 0750 "$MXB_STATE_DIR/tmp"
    ensure_dir 0750 "$MXB_LOG_DIR"
    ensure_dir 0750 "$MXB_LOG_DIR/diagnostics"
    ensure_dir 0700 "$MXB_BACKUP_DIR"
    ensure_dir 0755 "$MXB_MAPS_DIR"
    ensure_dir 0755 "$MXB_INSTALL_DIR"
    ensure_dir 0755 "$MXB_INSTALL_DIR/bin"
    ensure_dir 0755 "$MXB_INSTALL_DIR/systemd"
    ensure_dir 0755 "$MXB_INSTALL_DIR/share/doc"
    ensure_dir 0755 "$MXB_SYSTEMD_DIR"
    ensure_dir 0755 "$MXB_LOGROTATE_DIR"
    ensure_dir 0755 "$MXB_BIN_DIR"
}

install_application() {
    local script
    for script in install.sh sync-mailcow.sh update.sh diagnose.sh update-scripts.sh; do
        install -m 0755 "$RELEASE_ROOT/bin/$script" "$MXB_INSTALL_DIR/bin/$script"
    done
    install -m 0644 "$RELEASE_ROOT/VERSION" "$MXB_INSTALL_DIR/VERSION"
    if [[ -f "$RELEASE_ROOT/SHA256SUMS" ]]; then
        install -m 0644 "$RELEASE_ROOT/SHA256SUMS" "$MXB_INSTALL_DIR/SHA256SUMS"
    else
        ( cd "$MXB_INSTALL_DIR" && find bin -type f -name '*.sh' -print0 | sort -z \
            | xargs -0 sha256sum >SHA256SUMS )
    fi
    local file sub
    for file in "$RELEASE_ROOT"/share/doc/*; do
        [[ -f "$file" ]] && install -m 0644 "$file" "$MXB_INSTALL_DIR/share/doc/"
    done
    if [[ -d "$RELEASE_ROOT/config" ]]; then
        ensure_dir 0755 "$MXB_INSTALL_DIR/config"
        for file in "$RELEASE_ROOT"/config/*; do
            [[ -f "$file" ]] && install -m 0644 "$file" "$MXB_INSTALL_DIR/config/"
        done
    fi

    # The release manifest covers these files, and update-scripts.sh reads the
    # unit files from the installed tree, so they must be present here too.
    for sub in systemd logrotate; do
        [[ -d "$RELEASE_ROOT/$sub" ]] || continue
        ensure_dir 0755 "$MXB_INSTALL_DIR/$sub"
        for file in "$RELEASE_ROOT/$sub"/*; do
            [[ -f "$file" ]] && install -m 0644 "$file" "$MXB_INSTALL_DIR/$sub/"
        done
    done

    ln -sfn "$MXB_INSTALL_DIR/bin/sync-mailcow.sh" "$MXB_BIN_DIR/sync-mailcow"
    ln -sfn "$MXB_INSTALL_DIR/bin/update.sh" "$MXB_BIN_DIR/mx-update"
    ln -sfn "$MXB_INSTALL_DIR/bin/diagnose.sh" "$MXB_BIN_DIR/mx-diagnose"
    ln -sfn "$MXB_INSTALL_DIR/bin/update-scripts.sh" "$MXB_BIN_DIR/mx-update-scripts"
    log "application installed in $MXB_INSTALL_DIR"
}

install_units() {
    local unit
    for unit in mailcow-sync.service mailcow-sync.timer; do
        install -m 0644 "$RELEASE_ROOT/systemd/$unit" "$MXB_SYSTEMD_DIR/$unit"
    done
    systemctl daemon-reload
    systemctl enable mailcow-sync.timer
    systemctl start mailcow-sync.timer
    log "systemd timer enabled"
}

install_logrotate() {
    mkdir -p "$MXB_LOGROTATE_DIR"
    if [[ -f "$RELEASE_ROOT/logrotate/mailcow-backup-mx" ]]; then
        install -m 0644 "$RELEASE_ROOT/logrotate/mailcow-backup-mx" "$MXB_LOGROTATE_DIR/mailcow-backup-mx"
    else
        cat >"$MXB_LOGROTATE_DIR/mailcow-backup-mx" <<'EOF'
/var/log/mailcow-backup-mx/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF
    fi
}

configure_postfix() {
    local maps="$MXB_MAPS_DIR" compat
    local -a settings=()

    mkdir -p "$MXB_POSTFIX_ETC"
    if [[ ! -f "$MXB_POSTFIX_ETC/main.cf.pre-mx-backup-mailcow" ]]; then
        cp -p "$MXB_POSTFIX_ETC/main.cf" "$MXB_POSTFIX_ETC/main.cf.pre-mx-backup-mailcow" 2>/dev/null || true
    fi

    compat=$(postconf -d compatibility_level 2>/dev/null | awk '{print $3}')
    [[ -n "$compat" ]] || compat="3.6"

    settings=(
        "compatibility_level = $compat"
        "myhostname = ${BACKUP_MX_HOSTNAME:-localhost}"
        "mydomain = ${BACKUP_MX_HOSTNAME#*.}"
        "myorigin = \$myhostname"
        "mydestination = localhost, localhost.localdomain"
        "inet_interfaces = all"
        "inet_protocols = all"
        "mynetworks_style = host"
        "mynetworks = 127.0.0.0/8 [::1]/128"
        "biff = no"
        "append_dot_mydomain = no"
        "smtpd_banner = \$myhostname ESMTP"
        "relayhost ="
        "relay_domains = hash:$maps/relay_domains"
        "relay_recipient_maps = hash:$maps/relay_recipients"
        "transport_maps = hash:$maps/transport"
        "smtp_tls_policy_maps = hash:$maps/smtp_tls_policy"
        "alias_maps = hash:$maps/aliases"
        "alias_database = hash:$maps/aliases"
        "local_recipient_maps ="
        "virtual_alias_maps ="
        "virtual_mailbox_domains ="
        "virtual_mailbox_maps ="
        "smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination"
        "smtpd_recipient_restrictions = permit_mynetworks, reject_invalid_helo_hostname, reject_unauth_destination"
        "smtpd_client_restrictions ="
        "smtpd_sender_restrictions ="
        "smtpd_helo_required = yes"
        "smtpd_reject_unlisted_recipient = yes"
        "smtpd_forbid_bare_newline = yes"
        "smtpd_data_restrictions = reject_unauth_pipelining"
        "disable_vrfy_command = yes"
        "smtpd_sasl_auth_enable = no"
        "relay_domains_reject_code = 550"
        "unknown_relay_recipient_reject_code = 550"
        "parent_domain_matches_subdomains ="
        "recipient_delimiter = +"
        "maximal_queue_lifetime = $QUEUE_LIFETIME"
        "bounce_queue_lifetime = 1d"
        "queue_run_delay = 300s"
        "minimal_backoff_time = 600s"
        "maximal_backoff_time = 1800s"
        "delay_warning_time = 4h"
        "message_size_limit = $MESSAGE_SIZE_LIMIT"
        "mailbox_size_limit = 0"
        "smtpd_tls_security_level = may"
        "smtpd_tls_protocols = >=TLSv1.2"
        "smtp_tls_security_level = may"
        "smtp_tls_protocols = >=TLSv1.2"
        "smtp_tls_loglevel = 1"
        "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
    )

    local item
    for item in "${settings[@]}"; do
        postconf -e "$item" >>"$MXB_LOG_DIR/install.log" 2>&1 \
            || die "postconf failed for: $item"
    done

    # Local operational mail is discarded: this server never stores mail.
    cat >"$maps/aliases" <<'EOF'
# Managed by mx-backup-mailcow: local operational mail is discarded.
postmaster: /dev/null
root: /dev/null
mailer-daemon: /dev/null
double-bounce: /dev/null
nobody: /dev/null
hostmaster: /dev/null
webmaster: /dev/null
abuse: /dev/null
security: /dev/null
EOF
    chmod 0644 "$maps/aliases"
    postmap "hash:$maps/aliases" || die "postmap failed for the local aliases map"

    # Seed empty maps so that Postfix can start before the first sync.
    local name
    for name in relay_domains relay_recipients transport smtp_tls_policy; do
        if [[ ! -f "$maps/$name" ]]; then
            : >"$maps/$name"
            chmod 0644 "$maps/$name"
        fi
        postmap "hash:$maps/$name" >>"$MXB_LOG_DIR/install.log" 2>&1 \
            || die "postmap failed for $name"
    done

    systemctl enable postfix
    if systemctl is-active --quiet postfix; then
        postfix reload
    else
        systemctl start postfix
    fi
    postfix check >>"$MXB_LOG_DIR/install.log" 2>&1 || warn "postfix check reported issues"
    log "Postfix configured as a backup MX"
}

detect_ssh_ports() {
    local files=() file port
    local -a ports=()
    [[ -r "$MXB_SSH_DIR/sshd_config" ]] && files+=("$MXB_SSH_DIR/sshd_config")
    while IFS= read -r file; do
        files+=("$file")
    done < <(find "$MXB_SSH_DIR/sshd_config.d" -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort)
    for file in "${files[@]}"; do
        while IFS= read -r port; do
            [[ "$port" =~ ^[0-9]+$ ]] && ports+=("$port")
        done < <(awk 'tolower($1)=="port" {print $2}' "$file" 2>/dev/null)
    done
    if (( ${#ports[@]} == 0 )); then
        ports=(22)
    fi
    printf '%s\n' "${ports[@]}" | sort -un
}

configure_firewall() {
    [[ "$NO_FIREWALL" -eq 1 ]] && { log "skipping firewall configuration (--no-firewall)"; return 0; }
    if ! command -v ufw >/dev/null 2>&1; then
        warn "ufw is not installed; skipping firewall configuration"
        return 0
    fi
    local port
    local -a ports=()
    mapfile -t ports < <(detect_ssh_ports)
    if (( ${#ports[@]} == 0 )); then
        warn "could not determine the SSH port; not enabling UFW to avoid lockout"
        return 0
    fi
    ufw --force default deny incoming
    ufw --force default allow outgoing
    for port in "${ports[@]}"; do
        ufw allow "$port/tcp" comment 'SSH'
    done
    ufw allow 25/tcp comment 'SMTP backup MX'
    if ! ufw status | grep -q '^Status: active'; then
        ufw --force enable
    fi
    log "firewall configured (SSH: ${ports[*]}, SMTP: 25)"
}

verify_api_access() {
    local code rc=0
    local -a args=(
        --silent --show-error --proto '=https' --tlsv1.2
        --connect-timeout 10 --max-time 30
        --header 'Accept: application/json'
        --output /dev/null
        --write-out '%{http_code}'
    )
    if [[ -n "$MAILCOW_API_CA_FILE" ]]; then
        args+=(--cacert "$MAILCOW_API_CA_FILE")
    fi
    code=$(printf 'url = "https://%s/api/v1/get/domain/all"\nheader = "X-API-Key: %s"\n' \
        "$MAILCOW_HOST" "$MAILCOW_API_KEY" \
        | curl "${args[@]}" --config - 2>>"$MXB_LOG_DIR/install.log") || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        die "cannot reach the Mailcow API at https://$MAILCOW_HOST (curl exit $rc)"
    fi
    case "$code" in
        200) log "Mailcow API reachable and authenticated" ;;
        401|403) die "Mailcow API rejected the credentials (HTTP $code): verify the read-only key and the IP allowlist" ;;
        000) die "cannot reach the Mailcow API at https://$MAILCOW_HOST (DNS, firewall or TLS)" ;;
        *) die "Mailcow API returned HTTP $code" ;;
    esac
}

run_initial_sync() {
    [[ "$SKIP_INITIAL_SYNC" -eq 1 ]] && { log "skipping initial synchronization"; return 0; }
    log "running initial Mailcow synchronization"
    if ! "$MXB_INSTALL_DIR/bin/sync-mailcow.sh"; then
        err "initial synchronization failed; the server is installed and the timer will retry every 2 hours"
        err "check the API key, the IP allowlist and connectivity, then run: sync-mailcow.sh"
        return 1
    fi
    return 0
}

print_summary() {
    local state="$MXB_STATE_DIR/state/sync-state.json" domains="?" mailboxes="?"
    if [[ -r "$state" ]]; then
        domains=$(jq -r '.counts.domains // "?"' "$state" 2>/dev/null || printf '?')
        mailboxes=$(jq -r '.counts.mailboxes // "?"' "$state" 2>/dev/null || printf '?')
    fi
    cat <<EOF

Installation complete.

  Backup MX hostname : ${BACKUP_MX_HOSTNAME:-unknown}
  Mailcow host       : $MAILCOW_HOST
  Primary IP         : $MAILCOW_PRIMARY_IP:$MAILCOW_PRIMARY_PORT
  Application        : $MXB_INSTALL_DIR (version $RESOLVED_VERSION)
  Configuration      : $MXB_CONFIG_FILE (0600)
  Domains / mailboxes: $domains / $mailboxes
  Timer              : mailcow-sync.timer (every 2 hours, persistent)

Next steps:
  1. DNS: add "MX 20 ${BACKUP_MX_HOSTNAME:-<this-host>}." to every domain hosted by Mailcow,
     and include the backup MX IP in the SPF record if it sends DSNs directly.
  2. Mailcow: allowlist $MAILCOW_PRIMARY_IP's partner IP (this server) in
     data/conf/postfix/custom_postscreen_whitelist.cidr and in rspamd if greylisting is strict.
  3. Verify mail flow during a maintenance window.

Useful commands:
  sync-mailcow.sh --dry-run     # preview a synchronization
  mx-diagnose                   # generate an AI-ready health report
  mx-update-scripts --check     # check for application updates
  mx-update                     # update Ubuntu packages
EOF
}

main() {
    parse_args "$@"
    require_root
    check_os
    check_hostname
    load_existing_config
    interactive_config
    validate_config

    if [[ "$NON_INTERACTIVE" -eq 0 && "$ASSUME_YES" -eq 0 ]]; then
        local answer=""
        printf '\nProceed with installation? [y/N] '
        IFS= read -r answer || true
        [[ "$answer" =~ ^[Yy]$ ]] || die "installation cancelled"
    fi

    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mx-backup-mailcow.XXXXXX")
    verify_installer
    ensure_curl

    if [[ -n "$LOCAL_DIR" ]]; then
        prepare_local_tree "$LOCAL_DIR"
    else
        resolve_version
        fetch_release
    fi

    apt_upgrade
    install_packages
    if ! command -v jq >/dev/null 2>&1; then
        die "jq is required but was not installed"
    fi

    create_directories
    install_application
    install_units
    install_logrotate
    write_config
    configure_postfix
    configure_firewall
    verify_api_access

    if ! run_initial_sync; then
        print_summary
        exit 1
    fi

    print_summary
    exit 0
}

main "$@"
