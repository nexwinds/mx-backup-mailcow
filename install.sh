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
RE_EMAIL='^[A-Za-z0-9._%+-]+@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9]([a-z0-9-]{0,57}[a-z0-9])?)$'
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
: "${MXB_POSTFIX_TEMPLATE_DIR:=/usr/share/postfix}"
: "${MXB_SSH_DIR:=/etc/ssh}"
: "${MXB_CA_BUNDLE:=/etc/ssl/certs/ca-certificates.crt}"
: "${MXB_LETSENCRYPT_DIR:=/etc/letsencrypt}"
: "${MXB_RENEWAL_HOOK_DIR:=$MXB_LETSENCRYPT_DIR/renewal-hooks/deploy}"

MANAGED_KEYS=(
    BACKUP_MX_HOSTNAME
    MAILCOW_HOST
    MAILCOW_API_KEY
    MAILCOW_API_CA_FILE
    MAILCOW_PRIMARY_IP
    MAILCOW_PRIMARY_PORT
    SMTP_TLS_MODE
    SMTP_TLS_MATCH_HOSTNAME
    SMTPD_TLS_CERT_FILE
    SMTPD_TLS_KEY_FILE
    OPERATIONAL_MAIL_TO
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
ARG_MX_HOSTNAME=""
ARG_OPERATIONAL_MAIL=""
ARG_TLS_CERT=""
ARG_TLS_KEY=""
ARG_NO_INBOUND_TLS=0
INBOUND_TLS_RENEWAL=0

DETECTED_FQDN=""

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
  --smtp-tls-mode MODE      secure (default) or may (unverified TLS)
  --tls-match HOSTNAME      Certificate hostname for SMTP_TLS_MODE=secure
                            (defaults to MAILCOW_HOST)
  --hostname FQDN           Postfix identity for this server (default: hostname -f)

Inbound TLS and operational mail:
  --inbound-tls-cert PATH   Certificate chain offered to inbound MTAs
  --inbound-tls-key PATH    Private key for --inbound-tls-cert
                            (by default an existing certbot certificate is used;
                            without one, install.sh requests one from Let's
                            Encrypt when the hostname and TCP/80 allow it)
  --no-inbound-tls          Do not offer STARTTLS on port 25 and do not request
                            a certificate
  --operational-mail ADDR   Forward root/postmaster/abuse mail here
                            (default: discard, this server stores no mail)

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
have() { command -v "$1" >/dev/null 2>&1; }

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

detect_fqdn() {
    local fqdn=""
    fqdn=$(hostname -f 2>/dev/null || true)
    [[ -n "$fqdn" ]] || fqdn=$(hostname 2>/dev/null || true)
    printf '%s' "${fqdn,,}"
}

# Postfix derives $myorigin, the HELO name and the DSN sender domain from
# $myhostname, which must be a fully qualified domain name. A single-label
# hostname makes receivers reject the HELO, puts an unverifiable domain in
# every bounce, and prevents issuing a certificate for inbound TLS.
check_hostname() {
    local fqdn=${DETECTED_FQDN:-} candidate
    if [[ -z "$fqdn" ]]; then
        fqdn=$(detect_fqdn)
        DETECTED_FQDN=$fqdn
    fi
    candidate=${BACKUP_MX_HOSTNAME:-}
    candidate=${candidate,,}
    candidate=${candidate%.}
    [[ "$candidate" =~ $RE_DOMAIN ]] && return 0

    if [[ "$FORCE" -eq 1 ]]; then
        warn "the Postfix hostname '${candidate:-unknown}' is not a fully qualified domain name; continuing due to --force. Postfix will use '${candidate:-unknown}' as its HELO and DSN domain, which receivers may reject."
        return 0
    fi
    if [[ -n "$candidate" && "$candidate" != "$fqdn" ]]; then
        die "the Postfix hostname '${candidate}' is not a fully qualified domain name; use --hostname mx.example.com or fix BACKUP_MX_HOSTNAME in $MXB_CONFIG_FILE"
    fi
    die "the server hostname '${fqdn:-unknown}' is not a fully qualified domain name ('hostname -f' must contain a dot); set it with 'hostnamectl set-hostname mx.example.com', add the name to /etc/hosts, or pass --hostname FQDN, then re-run"
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
            --hostname) ARG_MX_HOSTNAME=${2:?--hostname requires a FQDN}; shift ;;
            --operational-mail) ARG_OPERATIONAL_MAIL=${2:?--operational-mail requires an address}; shift ;;
            --inbound-tls-cert) ARG_TLS_CERT=${2:?--inbound-tls-cert requires a path}; shift ;;
            --inbound-tls-key) ARG_TLS_KEY=${2:?--inbound-tls-key requires a path}; shift ;;
            --no-inbound-tls) ARG_NO_INBOUND_TLS=1 ;;
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
    # The Postfix identity is the system FQDN unless the operator overrides it.
    BACKUP_MX_HOSTNAME=${DETECTED_FQDN:-}
    MAILCOW_HOST=""
    MAILCOW_API_KEY=""
    MAILCOW_API_CA_FILE=""
    MAILCOW_PRIMARY_IP=""
    MAILCOW_PRIMARY_PORT="25"
    # Authenticated TLS to the primary is the safe default: a policy of "may"
    # accepts any certificate (or none) on the hop that carries all queued mail.
    SMTP_TLS_MODE="secure"
    SMTP_TLS_MATCH_HOSTNAME=""
    SMTPD_TLS_CERT_FILE=""
    SMTPD_TLS_KEY_FILE=""
    OPERATIONAL_MAIL_TO=""
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
    [[ -n "$ARG_MX_HOSTNAME" ]] && BACKUP_MX_HOSTNAME=$ARG_MX_HOSTNAME
    [[ -n "$ARG_OPERATIONAL_MAIL" ]] && OPERATIONAL_MAIL_TO=$ARG_OPERATIONAL_MAIL
    [[ -n "$ARG_TLS_CERT" ]] && SMTPD_TLS_CERT_FILE=$ARG_TLS_CERT
    [[ -n "$ARG_TLS_KEY" ]] && SMTPD_TLS_KEY_FILE=$ARG_TLS_KEY

    MAILCOW_HOST=${MAILCOW_HOST,,}
    MAILCOW_HOST=${MAILCOW_HOST%.}
    SMTP_TLS_MATCH_HOSTNAME=${SMTP_TLS_MATCH_HOSTNAME,,}
    SMTP_TLS_MATCH_HOSTNAME=${SMTP_TLS_MATCH_HOSTNAME%.}
    BACKUP_MX_HOSTNAME=${BACKUP_MX_HOSTNAME,,}
    BACKUP_MX_HOSTNAME=${BACKUP_MX_HOSTNAME%.}

    # An explicit --no-inbound-tls must win over a certificate left in the
    # configuration file, otherwise STARTTLS stays on against the operator.
    if [[ "$ARG_NO_INBOUND_TLS" -eq 1 ]]; then
        SMTPD_TLS_CERT_FILE=""
        SMTPD_TLS_KEY_FILE=""
    fi

    # Use a Let's Encrypt certificate for the backup MX host when one exists.
    if [[ "$ARG_NO_INBOUND_TLS" -eq 0 && -n "$BACKUP_MX_HOSTNAME" \
        && -z "$SMTPD_TLS_CERT_FILE" && -z "$SMTPD_TLS_KEY_FILE" ]]; then
        local lesite="$MXB_LETSENCRYPT_DIR/live/$BACKUP_MX_HOSTNAME"
        if [[ -r "$lesite/fullchain.pem" && -r "$lesite/privkey.pem" ]]; then
            SMTPD_TLS_CERT_FILE="$lesite/fullchain.pem"
            SMTPD_TLS_KEY_FILE="$lesite/privkey.pem"
            log "using inbound TLS certificate $lesite/fullchain.pem"
        fi
    fi
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
    prompt BACKUP_MX_HOSTNAME "Postfix hostname for this server (FQDN)"
    prompt MAILCOW_HOST "Mailcow hostname (API endpoint)"
    prompt MAILCOW_PRIMARY_IP "Primary Mailcow IP address"
    prompt MAILCOW_API_KEY "Read-only API key" 1
    prompt MAILCOW_API_CA_FILE "Private CA file for the API (optional)"
    prompt OPERATIONAL_MAIL_TO "Forward root/postmaster mail to (blank: discard)"
    prompt SMTP_TLS_MODE "SMTP TLS mode for the primary (secure/may)"
}

validate_config() {
    MAILCOW_HOST=${MAILCOW_HOST,,}
    MAILCOW_HOST=${MAILCOW_HOST%.}
    BACKUP_MX_HOSTNAME=${BACKUP_MX_HOSTNAME,,}
    BACKUP_MX_HOSTNAME=${BACKUP_MX_HOSTNAME%.}
    [[ -n "$MAILCOW_HOST" ]] || die "MAILCOW_HOST is required (use --mailcow-host or --non-interactive with --config)"
    [[ -n "$MAILCOW_PRIMARY_IP" ]] || die "MAILCOW_PRIMARY_IP is required (use --primary-ip or --non-interactive with --config)"
    [[ -n "$MAILCOW_API_KEY" ]] || die "MAILCOW_API_KEY is required (use --api-key-stdin or --config)"

    [[ "$MAILCOW_HOST" =~ $RE_DOMAIN ]] \
        || die "MAILCOW_HOST is not a valid hostname: $MAILCOW_HOST"
    [[ "$MAILCOW_API_KEY" =~ ^[A-Za-z0-9-]+$ ]] || die "MAILCOW_API_KEY contains unexpected characters"
    (( ${#MAILCOW_API_KEY} >= 16 )) || die "MAILCOW_API_KEY is too short"

    if [[ "$BACKUP_MX_HOSTNAME" =~ $RE_DOMAIN ]]; then
        :
    elif [[ "$FORCE" -eq 1 ]]; then
        warn "the Postfix hostname '${BACKUP_MX_HOSTNAME:-unknown}' is not a fully qualified domain name; continuing due to --force. HELO checks, DSN SPF/DMARC validation and inbound TLS will fail for this identity."
    else
        die "the Postfix hostname '${BACKUP_MX_HOSTNAME:-unknown}' is not a fully qualified domain name; use --hostname mx.example.com"
    fi
    if [[ -n "$DETECTED_FQDN" && "$BACKUP_MX_HOSTNAME" != "$DETECTED_FQDN" ]]; then
        warn "Postfix will identify itself as $BACKUP_MX_HOSTNAME, which differs from the system hostname $DETECTED_FQDN; point the DNS A/AAAA and PTR of $BACKUP_MX_HOSTNAME at this server"
    fi

    if [[ -n "$OPERATIONAL_MAIL_TO" ]]; then
        OPERATIONAL_MAIL_TO=${OPERATIONAL_MAIL_TO,,}
        [[ "$OPERATIONAL_MAIL_TO" =~ $RE_EMAIL ]] \
            || die "OPERATIONAL_MAIL_TO is not a valid address: $OPERATIONAL_MAIL_TO"
    fi

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

    # The primary's certificate is issued for MAILCOW_HOST; requiring that name
    # is the only useful default, and an empty name would silently disable it.
    # Derive it here, after interactive_config, so the prompted host is used.
    if [[ "$SMTP_TLS_MODE" == "secure" && -z "$SMTP_TLS_MATCH_HOSTNAME" ]]; then
        SMTP_TLS_MATCH_HOSTNAME=$MAILCOW_HOST
    fi
    SMTP_TLS_MATCH_HOSTNAME=${SMTP_TLS_MATCH_HOSTNAME,,}
    SMTP_TLS_MATCH_HOSTNAME=${SMTP_TLS_MATCH_HOSTNAME%.}

    case "$SMTP_TLS_MODE" in
        may) ;;
        secure)
            [[ "$SMTP_TLS_MATCH_HOSTNAME" =~ $RE_DOMAIN ]] \
                || die "SMTP_TLS_MODE=secure requires a certificate name (--tls-match or MAILCOW_HOST)"
            ;;
        *) die "SMTP_TLS_MODE must be 'may' or 'secure'" ;;
    esac

    if [[ -z "$SMTPD_TLS_CERT_FILE" && -z "$SMTPD_TLS_KEY_FILE" ]]; then
        SMTPD_TLS_CERT_FILE=""
        SMTPD_TLS_KEY_FILE=""
    else
        [[ -n "$SMTPD_TLS_CERT_FILE" && -n "$SMTPD_TLS_KEY_FILE" ]] \
            || die "inbound TLS needs both SMTPD_TLS_CERT_FILE and SMTPD_TLS_KEY_FILE (use --inbound-tls-cert and --inbound-tls-key)"
        [[ -r "$SMTPD_TLS_CERT_FILE" ]] || die "inbound TLS certificate is not readable: $SMTPD_TLS_CERT_FILE (remove SMTPD_TLS_CERT_FILE/SMTPD_TLS_KEY_FILE or the --inbound-tls-* options to detect or request one automatically)"
        [[ -r "$SMTPD_TLS_KEY_FILE" ]] || die "inbound TLS private key is not readable: $SMTPD_TLS_KEY_FILE"
        if have openssl; then
            local cert_pub key_pub
            cert_pub=$(openssl x509 -in "$SMTPD_TLS_CERT_FILE" -noout -pubkey 2>/dev/null || true)
            key_pub=$(openssl pkey -in "$SMTPD_TLS_KEY_FILE" -pubout 2>/dev/null || true)
            [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] \
                || die "the inbound TLS key does not match the certificate ($SMTPD_TLS_KEY_FILE / $SMTPD_TLS_CERT_FILE)"
            openssl x509 -in "$SMTPD_TLS_CERT_FILE" -noout -checkhost "$BACKUP_MX_HOSTNAME" >/dev/null 2>&1 \
                || die "the inbound TLS certificate does not cover $BACKUP_MX_HOSTNAME; use --no-inbound-tls to install without STARTTLS"
            openssl x509 -in "$SMTPD_TLS_CERT_FILE" -noout -checkend 0 >/dev/null 2>&1 \
                || die "the inbound TLS certificate has expired or is not yet valid: $SMTPD_TLS_CERT_FILE"
        else
            warn "openssl is not available; the inbound TLS certificate was not validated"
        fi
    fi

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
        mkdir -p "$root/bin" "$root/systemd" "$root/share/doc" "$root/share/mailcow" "$root/config" "$root/logrotate"
        cp -f "$dir"/sync-mailcow.sh "$dir"/update.sh "$dir"/diagnose.sh "$dir"/update-scripts.sh "$dir"/install.sh "$root/bin/"
        cp -f "$dir/VERSION" "$root/VERSION" 2>/dev/null || printf '%s\n' "$VERSION" >"$root/VERSION"
        [[ -d "$dir/systemd" ]] && cp -f "$dir/systemd"/* "$root/systemd/" 2>/dev/null || true
        [[ -d "$dir/mailcow" ]] && cp -f "$dir/mailcow"/* "$root/share/mailcow/" 2>/dev/null || true
        [[ -d "$dir/config" ]] && cp -f "$dir/config"/* "$root/config/" 2>/dev/null || true
        [[ -d "$dir/logrotate" ]] && cp -f "$dir/logrotate"/* "$root/logrotate/" 2>/dev/null || true
        [[ -f "$dir/README.md" ]] && cp -f "$dir/README.md" "$root/share/doc/"
        [[ -f "$dir/OPERATIONS.md" ]] && cp -f "$dir/OPERATIONS.md" "$root/share/doc/"
        [[ -f "$dir/TROUBLESHOOTING.md" ]] && cp -f "$dir/TROUBLESHOOTING.md" "$root/share/doc/"
        [[ -f "$dir/DOCS.md" ]] && cp -f "$dir/DOCS.md" "$root/share/doc/"
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

    if [[ -d "$RELEASE_ROOT/share/mailcow" ]]; then
        ensure_dir 0755 "$MXB_INSTALL_DIR/share/mailcow"
        for file in "$RELEASE_ROOT"/share/mailcow/*; do
            [[ -f "$file" ]] && install -m 0755 "$file" "$MXB_INSTALL_DIR/share/mailcow/"
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

# The Ubuntu postfix package skips main.cf when it is installed with the
# "No configuration" mailer type (which this installer selects so the package
# never starts with stock settings), and some releases skip master.cf as well.
# Postfix then refuses to start and every postconf call fails, so the package
# templates must be restored before the configuration is written.
ensure_postfix_config() {
    local dir=$1 name src candidate
    local -a candidates

    for name in main.cf master.cf; do
        [[ -f "$dir/$name" ]] && continue
        if [[ "$name" == "main.cf" ]]; then
            candidates=(
                "$MXB_POSTFIX_TEMPLATE_DIR/main.cf.debian"
                "$MXB_POSTFIX_TEMPLATE_DIR/main.cf.proto"
                "$MXB_POSTFIX_TEMPLATE_DIR/main.cf.default"
                "/etc/postfix/main.cf.proto"
                "/usr/share/postfix/main.cf.proto"
            )
        else
            candidates=(
                "$MXB_POSTFIX_TEMPLATE_DIR/master.cf.dist"
                "$MXB_POSTFIX_TEMPLATE_DIR/master.cf.proto"
                "/etc/postfix/master.cf.proto"
                "/usr/lib/postfix/master.cf.dist"
            )
        fi
        src=""
        for candidate in "${candidates[@]}"; do
            [[ -r "$candidate" ]] && { src=$candidate; break; }
        done
        [[ -n "$src" ]] || die "no Postfix $name template found; reinstall the postfix package"
        install -m 0644 "$src" "$dir/$name"
        log "restored $dir/$name from $src"
    done
}

# Postfix reports the compiled-in default (0) when no main.cf sets a
# compatibility level. Levels below 2 select legacy compatibility defaults,
# so prefer the effective value, then the value in main.cf, then the default.
valid_compatibility_level() {
    local value=${1:-}
    [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
    (( ${value%%.*} >= 2 ))
}

postfix_compatibility_level() {
    local main_cf=$1 value=""

    if have postconf; then
        value=$(postconf -h compatibility_level 2>/dev/null | tr -d '[:space:]' || true)
        valid_compatibility_level "$value" && { printf '%s' "$value"; return 0; }
    fi
    if [[ -r "$main_cf" ]]; then
        value=$(awk -F= '/^[[:space:]]*compatibility_level[[:space:]]*=/ {
                   gsub(/[[:space:]]/, "", $2); print $2; exit }' "$main_cf" 2>/dev/null || true)
        valid_compatibility_level "$value" && { printf '%s' "$value"; return 0; }
    fi
    if have postconf; then
        value=$(postconf -d -h compatibility_level 2>/dev/null | tr -d '[:space:]' || true)
        valid_compatibility_level "$value" && { printf '%s' "$value"; return 0; }
    fi
    printf '3.6'
}

# The Quick start must work on a fresh VPS, where no certificate exists yet.
# Bring in certbot only when it is actually needed.
ensure_certbot() {
    have certbot && return 0
    have apt-get || return 1
    log "installing certbot for inbound TLS"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >>"$MXB_LOG_DIR/install.log" 2>&1 || return 1
    apt-get install -y -qq certbot >>"$MXB_LOG_DIR/install.log" 2>&1 || return 1
    have certbot
}

# Obtain a certificate for the Postfix identity when none is configured. A
# failure here is not fatal: the backup MX still accepts mail on port 25 without
# STARTTLS, and the warning names the DNS/port-80 fix and the manual command.
auto_provision_inbound_tls() {
    local lesite="$MXB_LETSENCRYPT_DIR/live/$BACKUP_MX_HOSTNAME"
    local out="" rc=0 opened_ufw=0 manual

    [[ "$ARG_NO_INBOUND_TLS" -eq 1 ]] && return 0
    [[ -n "$SMTPD_TLS_CERT_FILE" || -n "$SMTPD_TLS_KEY_FILE" ]] && return 0
    if [[ "${MXB_SKIP_AUTO_TLS:-0}" == "1" ]]; then
        log "automatic inbound TLS provisioning is disabled (MXB_SKIP_AUTO_TLS=1)"
        return 0
    fi
    if [[ ! "$BACKUP_MX_HOSTNAME" =~ $RE_DOMAIN ]]; then
        warn "cannot request an inbound TLS certificate for '${BACKUP_MX_HOSTNAME:-unknown}': not a fully qualified domain name"
        return 0
    fi
    if [[ -r "$lesite/fullchain.pem" && -r "$lesite/privkey.pem" ]]; then
        SMTPD_TLS_CERT_FILE="$lesite/fullchain.pem"
        SMTPD_TLS_KEY_FILE="$lesite/privkey.pem"
        log "using inbound TLS certificate $lesite/fullchain.pem"
        return 0
    fi

    manual="certbot certonly --standalone -d $BACKUP_MX_HOSTNAME"
    if have getent && ! getent ahosts "$BACKUP_MX_HOSTNAME" >/dev/null 2>&1; then
        warn "$BACKUP_MX_HOSTNAME does not resolve; skipping the automatic certificate request. Publish its A/AAAA record, then run: $manual (or re-run install.sh)"
        return 0
    fi
    if ! ensure_certbot; then
        warn "certbot is not installed and could not be installed; continuing without inbound STARTTLS. Install it with 'apt-get install -y certbot', then run: $manual (or re-run install.sh)"
        return 0
    fi

    log "no inbound TLS certificate found; requesting one from Let's Encrypt for $BACKUP_MX_HOSTNAME (TCP/80 must be reachable)"
    if [[ "$NO_FIREWALL" -eq 0 ]] && have ufw \
        && ufw status 2>/dev/null | grep -q '^Status: active' \
        && ! ufw status 2>/dev/null | grep -q '^80/tcp'; then
        if ufw allow 80/tcp comment 'ACME HTTP-01' >/dev/null 2>&1; then
            opened_ufw=1
        fi
    fi
    out=$(certbot certonly --standalone --preferred-challenges http \
        --config-dir "$MXB_LETSENCRYPT_DIR" \
        --non-interactive --agree-tos --register-unsafely-without-email \
        --keep-until-expiring --domain "$BACKUP_MX_HOSTNAME" 2>&1) || rc=$?
    printf '%s\n' "$out" >>"$MXB_LOG_DIR/install.log"

    if [[ "$rc" -eq 0 && -r "$lesite/fullchain.pem" && -r "$lesite/privkey.pem" ]]; then
        SMTPD_TLS_CERT_FILE="$lesite/fullchain.pem"
        SMTPD_TLS_KEY_FILE="$lesite/privkey.pem"
        log "obtained an inbound TLS certificate for $BACKUP_MX_HOSTNAME"
        return 0
    fi
    if [[ "$opened_ufw" -eq 1 ]]; then
        ufw delete allow 80/tcp >/dev/null 2>&1 || true
    fi
    warn "could not obtain an inbound TLS certificate for $BACKUP_MX_HOSTNAME (certbot exit $rc); continuing without STARTTLS. Make the name resolve here, allow TCP/80, then run: $manual (or re-run install.sh)"
}

# Postfix reads the TLS key as the unprivileged "postfix" user, so a Let's
# Encrypt key (mode 0600 root and a 0700 parent directory) is unusable where it
# lives. Stage the chain and key in a Postfix-readable directory, and install a
# certbot deploy hook so renewals update the copies instead of leaving Postfix
# with the expired certificate.
provision_inbound_tls() {
    local source_cert=${SMTPD_TLS_CERT_FILE:-} source_key=${SMTPD_TLS_KEY_FILE:-}
    local dir="$MXB_POSTFIX_ETC/tls" group=postfix target_cert target_key
    INBOUND_TLS_RENEWAL=0

    if [[ -z "$source_cert" ]]; then
        local param
        for param in smtpd_tls_cert_file smtpd_tls_key_file; do
            if [[ -n "$(postconf -h "$param" 2>/dev/null || true)" ]]; then
                postconf -X "$param" || die "cannot remove stale $param"
                log "removed stale $param: inbound STARTTLS is disabled"
            fi
        done
        SMTPD_TLS_CERT_FILE=""
        SMTPD_TLS_KEY_FILE=""
        return 0
    fi

    getent group postfix >/dev/null 2>&1 || group=root
    mkdir -p "$dir"
    if [[ "$(id -u)" -eq 0 ]]; then
        chown root:"$group" "$dir" || die "cannot set ownership of $dir"
    fi
    chmod 0750 "$dir"
    target_cert="$dir/${BACKUP_MX_HOSTNAME}.crt"
    target_key="$dir/${BACKUP_MX_HOSTNAME}.key"

    if [[ "$(id -u)" -eq 0 ]]; then
        install -m 0644 -o root -g "$group" "$source_cert" "$target_cert" \
            || die "cannot stage the inbound TLS certificate"
        install -m 0640 -o root -g "$group" "$source_key" "$target_key" \
            || die "cannot stage the inbound TLS key"
    else
        install -m 0644 "$source_cert" "$target_cert" || die "cannot stage the inbound TLS certificate"
        install -m 0640 "$source_key" "$target_key" || die "cannot stage the inbound TLS key"
    fi

    if have runuser && id -u postfix >/dev/null 2>&1; then
        runuser -u postfix -- test -r "$target_cert" \
            || die "the postfix user cannot read $target_cert"
        runuser -u postfix -- test -r "$target_key" \
            || die "the postfix user cannot read $target_key"
    fi

    SMTPD_TLS_CERT_FILE=$target_cert
    SMTPD_TLS_KEY_FILE=$target_key
    log "inbound TLS certificate staged in $dir"

    case "$source_cert" in
        "$MXB_LETSENCRYPT_DIR"/*)
            INBOUND_TLS_RENEWAL=1
            install_renewal_hook "$source_cert" "$source_key" "$group"
            ;;
        *)
            warn "inbound TLS material is not managed by certbot; renew $source_cert and re-run install.sh before it expires"
            ;;
    esac
}

install_renewal_hook() {
    local source_cert=$1 source_key=$2 group=$3
    local dir="$MXB_RENEWAL_HOOK_DIR" hook="$MXB_RENEWAL_HOOK_DIR/mx-backup-mailcow-tls"
    local target_cert="$MXB_POSTFIX_ETC/tls/${BACKUP_MX_HOSTNAME}.crt"
    local target_key="$MXB_POSTFIX_ETC/tls/${BACKUP_MX_HOSTNAME}.key"

    install -d -m 0755 "$dir" || die "cannot create $dir"
    cat >"$hook" <<EOF
#!/bin/sh
# Installed by mx-backup-mailcow: keep the Postfix copy of the certificate in
# sync with the certbot renewal store.
set -e
install -m 0644 -o root -g $group "$source_cert" "$target_cert"
install -m 0640 -o root -g $group "$source_key" "$target_key"
postfix reload
EOF
    chmod 0755 "$hook"
    log "installed certbot renewal hook $hook"
}

# A chrooted Postfix process resolves paths inside the queue directory, so a
# map under /etc/postfix is invisible to it. Either the maps live in the jail
# or the service must not be chrooted; the upstream default is the latter.
ensure_map_visibility() {
    local queue_dir jail_path service field
    queue_dir=$(postconf -h queue_directory 2>/dev/null || true)
    [[ -n "$queue_dir" ]] || queue_dir=$(postconf -d -h queue_directory 2>/dev/null || true)
    if [[ -z "$queue_dir" ]]; then
        warn "cannot determine Postfix queue_directory; the chroot/map visibility check was skipped"
        return 0
    fi
    jail_path="${queue_dir%/}$MXB_MAPS_DIR"

    for service in smtp/inet smtp/unix; do
        field=$(postconf -F "${service}/chroot" 2>/dev/null || true)
        [[ "$field" == *"=y" ]] || continue
        if [[ -e "$jail_path/relay_recipients.db" ]]; then
            log "$service runs chrooted and the maps are visible inside $queue_dir"
            continue
        fi
        postconf -F "${service}/chroot=n" \
            || die "cannot disable chroot for $service"
        log "disabled chroot for $service: it must read $MXB_MAPS_DIR, which is not inside $queue_dir"
    done
}

# These services deliver locally or run external commands; a backup MX uses
# neither, so remove the entries instead of leaving unused mail paths behind.
prune_unused_services() {
    local entry
    for entry in uucp/unix lmtp/unix virtual/unix; do
        [[ -n "$(postconf -M "$entry" 2>/dev/null || true)" ]] || continue
        postconf -MX "$entry" || die "cannot remove the unused $entry service"
        log "removed the unused $entry service from master.cf"
    done
}

configure_postfix() {
    local maps="$MXB_MAPS_DIR" compat
    local -a settings=()

    mkdir -p "$MXB_POSTFIX_ETC"
    ensure_postfix_config "$MXB_POSTFIX_ETC"
    if [[ ! -f "$MXB_POSTFIX_ETC/main.cf.pre-mx-backup-mailcow" ]]; then
        cp -p "$MXB_POSTFIX_ETC/main.cf" "$MXB_POSTFIX_ETC/main.cf.pre-mx-backup-mailcow" 2>/dev/null || true
    fi

    compat=$(postfix_compatibility_level "$MXB_POSTFIX_ETC/main.cf")
    log "using Postfix compatibility_level $compat"

    provision_inbound_tls

    settings=(
        "compatibility_level = $compat"
        "myhostname = $BACKUP_MX_HOSTNAME"
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
        "smtpd_forbid_unauth_pipelining = yes"
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
    if [[ -n "$SMTPD_TLS_CERT_FILE" ]]; then
        settings+=(
            "smtpd_tls_cert_file = $SMTPD_TLS_CERT_FILE"
            "smtpd_tls_key_file = $SMTPD_TLS_KEY_FILE"
        )
        log "inbound STARTTLS enabled with $SMTPD_TLS_CERT_FILE"
    else
        warn "inbound STARTTLS is disabled (no certificate): senders that enforce MTA-STS or DANE cannot deliver to this MX. Obtain a certificate for $BACKUP_MX_HOSTNAME and re-run install.sh"
    fi

    local item
    for item in "${settings[@]}"; do
        postconf -e "$item" >>"$MXB_LOG_DIR/install.log" 2>&1 \
            || die "postconf failed for: $item"
    done
    [[ -s "$MXB_POSTFIX_ETC/main.cf" ]] \
        || die "Postfix main.cf is missing after configuration"

    ensure_map_visibility
    prune_unused_services

    # Local operational mail either goes to the operator or (by explicit
    # default) nowhere: this server never stores mail.
    local mail_target=${OPERATIONAL_MAIL_TO:-/dev/null} alias_comment
    if [[ -n "$OPERATIONAL_MAIL_TO" ]]; then
        alias_comment="local operational mail is forwarded to $OPERATIONAL_MAIL_TO"
    else
        alias_comment="local operational mail is discarded (set OPERATIONAL_MAIL_TO to receive it)"
    fi
    cat >"$maps/aliases" <<EOF
# Managed by mx-backup-mailcow: $alias_comment.
postmaster: $mail_target
root: $mail_target
mailer-daemon: $mail_target
double-bounce: $mail_target
nobody: $mail_target
hostmaster: $mail_target
webmaster: $mail_target
abuse: $mail_target
security: $mail_target
EOF
    chmod 0644 "$maps/aliases"
    have postalias || die "postalias is missing from the postfix package; reinstall postfix"
    postalias "hash:$maps/aliases" || die "postalias failed for the local aliases map"
    log "operational mail aliases written ($alias_comment)"

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

    # The package may skip its spool permission fixup when installed with the
    # "No configuration" mailer type; running it again is idempotent.
    postfix set-permissions >>"$MXB_LOG_DIR/install.log" 2>&1 \
        || warn "postfix set-permissions reported issues"

    systemctl enable postfix
    if systemctl is-active --quiet postfix; then
        postfix reload
    else
        systemctl start postfix \
            || die "Postfix did not start; inspect: journalctl -u postfix -n 50 --no-pager"
    fi
    if ! systemctl is-active --quiet postfix; then
        die "Postfix is not active after start; inspect: journalctl -u postfix -n 50 --no-pager"
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
    local extra=""
    if [[ "$INBOUND_TLS_RENEWAL" -eq 1 ]]; then
        ufw allow 80/tcp comment 'ACME HTTP-01 renewal'
        extra=", HTTP: 80 (ACME renewal)"
    fi
    if ! ufw status | grep -q '^Status: active'; then
        ufw --force enable
    fi
    log "firewall configured (SSH: ${ports[*]}, SMTP: 25${extra})"
}

# TLS validity, queue lifetimes and log correlation all depend on an accurate
# clock. systemd-timesyncd synchronises shortly after boot; wait for that
# bounded event instead of proceeding with a clock that may jump later.
require_clock_sync() {
    local deadline=${MXB_CLOCK_WAIT_SECONDS:-30} waited=0 state=""
    if [[ "${MXB_SKIP_CLOCK_CHECK:-0}" == "1" ]]; then
        log "skipping the clock check (MXB_SKIP_CLOCK_CHECK=1)"
        return 0
    fi
    if ! have timedatectl; then
        warn "timedatectl is not available; the clock synchronization state could not be verified"
        return 0
    fi
    while :; do
        state=$(timedatectl show -p NTPSynchronized --value 2>/dev/null | tr -d '[:space:]' || true)
        [[ "$state" == "yes" ]] && break
        (( waited >= deadline )) && break
        sleep 1
        waited=$((waited + 1))
    done
    if [[ "$state" == "yes" ]]; then
        log "system clock is synchronized"
        return 0
    fi
    if [[ "$FORCE" -eq 1 ]]; then
        warn "the system clock is not synchronized; continuing due to --force. Certificate validation, queue lifetimes and log timestamps will be unreliable."
        return 0
    fi
    die "the system clock is not synchronized after ${deadline}s (state: ${state:-unknown}); check 'timedatectl timesync-status' and 'systemctl status systemd-timesyncd', then re-run"
}

# The forward hop carries all queued mail; with SMTP_TLS_MODE=secure it must
# verify, and with "may" the operator must know it does not.
verify_primary_smtp_tls() {
    local name=${SMTP_TLS_MATCH_HOSTNAME:-$MAILCOW_HOST} out="" rc=0 reason="" target
    if [[ "$MAILCOW_PRIMARY_IP" == *:* ]]; then
        target="[$MAILCOW_PRIMARY_IP]:$MAILCOW_PRIMARY_PORT"
    else
        target="$MAILCOW_PRIMARY_IP:$MAILCOW_PRIMARY_PORT"
    fi

    if ! have openssl; then
        warn "openssl is not available; the primary's SMTP certificate was not verified"
        return 0
    fi
    out=$(timeout 20 openssl s_client -starttls smtp -connect "$target" \
        -servername "$name" -verify_hostname "$name" -verify_return_error \
        </dev/null 2>&1) || rc=$?
    printf '%s\n' "$out" >>"$MXB_LOG_DIR/install.log"

    if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'Verify return code: 0'; then
        log "primary SMTP TLS verified for $name ($target)"
        return 0
    fi
    reason=$(printf '%s\n' "$out" | grep -m1 -E 'verify error|Verify return code|no peer certificate|handshake failure|wrong version' || true)
    if [[ "$SMTP_TLS_MODE" == "secure" ]]; then
        die "cannot verify TLS to the primary at $target for '$name' (${reason:-openssl exit $rc}); every queued message would be deferred. Fix the primary's certificate chain, or re-run with --smtp-tls-mode may to accept unverified TLS"
    fi
    warn "the primary at $target did not present a certificate verifiable as '$name' (${reason:-openssl exit $rc}); TLS to the primary is opportunistic and unauthenticated (SMTP_TLS_MODE=may)"
}

first_known_recipient() {
    local key=""
    [[ -r "$MXB_MAPS_DIR/relay_recipients" ]] || return 0
    key=$(awk -F'\t' '$1 ~ /@/ && $1 !~ /^@/ { print $1; exit }' "$MXB_MAPS_DIR/relay_recipients" 2>/dev/null || true)
    printf '%s' "$key"
}

# Read-only SMTP dialogue against the local listener. It proves that the SMTP
# server can read relay_recipients and that recipient validation behaves, which
# is what a chrooted smtpd or a stale map would break.
smtp_selftest() {
    local host=$1 port=$2 rc=0
    timeout 20 bash -c '
set -u
host=$1 port=$2 ehlo_name=$3 known=$4 unknown=$5
reply() {
    local line code out=""
    while IFS= read -r -t 8 line <&3; do
        out="$out$line
"
        code=${line:0:3}
        [[ ${line:3:1} == "-" ]] && continue
        printf "%s" "$out"
        return 0
    done
    return 1
}
exec 3<>"/dev/tcp/$host/$port" || { printf "connect=failed\n"; exit 7; }
banner=$(reply) || { printf "connect=no-banner\n"; exit 8; }
printf "banner_code=%s\n" "${banner:0:3}"
printf "EHLO %s\r\n" "$ehlo_name" >&3
ehlo=$(reply) || { printf "connect=no-ehlo\n"; exit 9; }
printf "ehlo_code=%s\n" "${ehlo:0:3}"
case "$ehlo" in *STARTTLS*) printf "starttls=yes\n" ;; *) printf "starttls=no\n" ;; esac
printf "MAIL FROM:<>\r\n" >&3
printf "mail_code=%s\n" "$(reply | cut -c1-3)"
printf "RCPT TO:<%s>\r\n" "$known" >&3
printf "known_code=%s\n" "$(reply | cut -c1-3)"
printf "RCPT TO:<%s>\r\n" "$unknown" >&3
printf "unknown_code=%s\n" "$(reply | cut -c1-3)"
printf "QUIT\r\n" >&3
exit 0
' _ "$host" "$port" "$BACKUP_MX_HOSTNAME" "$3" "$4" 2>/dev/null || rc=$?
    return "$rc"
}

probe_field() {
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

verify_smtp_path() {
    local known unknown domain out="" rc=0 banner starttls known_code unknown_code
    if [[ "${MXB_SKIP_SMTP_SELFTEST:-0}" == "1" ]]; then
        log "skipping the SMTP self-test (MXB_SKIP_SMTP_SELFTEST=1)"
        return 0
    fi
    known=$(first_known_recipient)
    if [[ -z "$known" ]]; then
        warn "no synchronized mailbox is available; the SMTP path was not self-tested"
        return 0
    fi
    domain=${known##*@}
    unknown="no-such-recipient-$$@$domain"

    out=$(smtp_selftest 127.0.0.1 25 "$known" "$unknown") || rc=$?
    if [[ "$rc" -ne 0 || -z "$out" ]]; then
        warn "the SMTP self-test could not complete (exit $rc); verify manually: swaks --to $known --server 127.0.0.1 --quit-after RCPT"
        return 0
    fi
    banner=$(probe_field "$out" banner_code)
    starttls=$(probe_field "$out" starttls)
    known_code=$(probe_field "$out" known_code)
    unknown_code=$(probe_field "$out" unknown_code)

    log "SMTP self-test: banner=${banner:-none} starttls=${starttls:-unknown} known_recipient=${known_code:-none} unknown_recipient=${unknown_code:-none}"

    case "$known_code" in
        2??) ;;
        *)
            die "the backup MX did not accept the synchronized recipient $known (SMTP $known_code); mail would be refused or queued. Check 'postmap -q $known hash:$MXB_MAPS_DIR/relay_recipients', 'postconf -h relay_recipient_maps' and 'journalctl -u postfix -n 50 --no-pager'"
            ;;
    esac
    case "$unknown_code" in
        5??) ;;
        *)
            warn "an unknown recipient at $domain was not rejected (SMTP $unknown_code); verify that the map is not in relaxed mode and that relay_recipients has no wildcard for this domain"
            ;;
    esac
    if [[ -n "$SMTPD_TLS_CERT_FILE" && "$starttls" != "yes" ]]; then
        die "inbound STARTTLS is configured but not advertised on 127.0.0.1:25; check 'postconf -h smtpd_tls_cert_file smtpd_tls_key_file' and 'journalctl -u postfix -n 50 --no-pager'"
    fi
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
    local inbound="disabled (no certificate)" outbound="$SMTP_TLS_MODE"
    local operational=${OPERATIONAL_MAIL_TO:-discarded (no OPERATIONAL_MAIL_TO)}
    if [[ -r "$state" ]]; then
        domains=$(jq -r '.counts.domains // "?"' "$state" 2>/dev/null || printf '?')
        mailboxes=$(jq -r '.counts.mailboxes // "?"' "$state" 2>/dev/null || printf '?')
    fi
    if [[ -n "$SMTPD_TLS_CERT_FILE" ]]; then
        inbound="enabled ($(postconf -h smtpd_tls_cert_file 2>/dev/null || printf '%s' "$SMTPD_TLS_CERT_FILE"))"
    fi
    [[ "$SMTP_TLS_MODE" == "secure" ]] || outbound="may (unverified)"
    cat <<EOF

Installation complete.

  Backup MX hostname : ${BACKUP_MX_HOSTNAME:-unknown}
  Mailcow host       : $MAILCOW_HOST
  Primary IP         : $MAILCOW_PRIMARY_IP:$MAILCOW_PRIMARY_PORT
  Application        : $MXB_INSTALL_DIR (version $RESOLVED_VERSION)
  Configuration      : $MXB_CONFIG_FILE (0600)
  Domains / mailboxes: $domains / $mailboxes
  Inbound STARTTLS   : $inbound
  Outbound SMTP TLS  : $outbound (certificate name: ${SMTP_TLS_MATCH_HOSTNAME:-none})
  Operational mail   : $operational
  Timer              : mailcow-sync.timer (every 2 hours, persistent)

Next steps:
  1. DNS: publish "MX 20 ${BACKUP_MX_HOSTNAME:-<this-host>}." (a FQDN with a
     trailing dot) for every Mailcow domain, and give ${BACKUP_MX_HOSTNAME:-<this-host>}
     A/AAAA records plus a matching PTR record.
  2. SPF: add "a:${BACKUP_MX_HOSTNAME:-<this-host>}" to the SPF record of domains this
     server may send bounces for.
  3. Mailcow: trust this server with the shipped script, run on the Mailcow host:
       scp /opt/mx-backup-mailcow/share/mailcow/allowlist-backup-mx.sh root@${MAILCOW_HOST}:/root/
       ssh root@${MAILCOW_HOST} 'bash /root/allowlist-backup-mx.sh --ip <this server public IP>'
     It allowlists this IP in postscreen and skips rspamd greylisting for it,
     and it is idempotent: re-run it after every Mailcow update.
  4. Verify mail flow in a maintenance window:
       swaks --to <known-mailbox> --server ${BACKUP_MX_HOSTNAME:-<this-host>} --quit-after RCPT
       mx-diagnose
EOF
    if [[ -z "$SMTPD_TLS_CERT_FILE" ]]; then
        if [[ "$ARG_NO_INBOUND_TLS" -eq 1 && "${MXB_SKIP_AUTO_TLS:-0}" == "1" ]]; then
            cat <<EOF
  5. Inbound TLS is off (--no-inbound-tls and MXB_SKIP_AUTO_TLS=1). Remove both
     opt-outs and re-run install.sh to request a Let's Encrypt certificate
     automatically.
EOF
        elif [[ "$ARG_NO_INBOUND_TLS" -eq 1 ]]; then
            cat <<EOF
  5. Inbound TLS is off (--no-inbound-tls). Re-run install.sh without that
     flag to request a Let's Encrypt certificate automatically.
EOF
        elif [[ "${MXB_SKIP_AUTO_TLS:-0}" == "1" ]]; then
            cat <<EOF
  5. Inbound TLS is off and automatic issuance is disabled
     (MXB_SKIP_AUTO_TLS=1). Unset it and re-run install.sh to request a
     Let's Encrypt certificate automatically.
EOF
        else
            cat <<EOF
  5. Inbound TLS is off. Once ${BACKUP_MX_HOSTNAME:-<this-host>} resolves here and
     TCP/80 is reachable, re-run install.sh: it requests a Let's Encrypt
     certificate automatically and turns STARTTLS on.
EOF
        fi
    fi
    cat <<EOF

Useful commands:
  sync-mailcow.sh --dry-run     # preview a synchronization
  mx-diagnose                   # health summary + AI-ready report
  mx-update-scripts --check     # check for application updates
  mx-update                     # update Ubuntu packages
EOF
}

main() {
    parse_args "$@"
    require_root
    check_os
    DETECTED_FQDN=$(detect_fqdn)
    load_existing_config
    interactive_config
    check_hostname
    validate_config
    require_clock_sync

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
    auto_provision_inbound_tls
    write_config
    configure_postfix
    configure_firewall
    verify_api_access
    verify_primary_smtp_tls

    if ! run_initial_sync; then
        print_summary
        exit 1
    fi

    verify_smtp_path
    print_summary
    exit 0
}

main "$@"
