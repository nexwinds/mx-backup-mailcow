#!/usr/bin/env bash
# shellcheck shell=bash
#
# Command mocks used by the test suite. They are exported as Bash functions,
# which works on Linux and on Git Bash for Windows (where extensionless
# executables cannot be launched).
#
# Behaviour is controlled through MOCK_* environment variables. Every
# invocation is appended to $MOCK_DIR/calls.log, which lets tests assert that
# destructive commands were never called.
#
set -uo pipefail

mock_log() { printf '%s\n' "$*" >>"${MOCK_DIR:?}/calls.log"; }

mock_set_unit_state() {
    local unit=$1 state=$2 file="$MOCK_DIR/systemd.state" line found=0
    touch "$file"
    : >"$file.tmp"
    while IFS= read -r line; do
        if [[ ${line%%=*} == "$unit" ]]; then
            printf '%s=%s\n' "$unit" "$state" >>"$file.tmp"
            found=1
        else
            printf '%s\n' "$line" >>"$file.tmp"
        fi
    done <"$file"
    if [[ "$found" -eq 0 ]]; then
        printf '%s=%s\n' "$unit" "$state" >>"$file.tmp"
    fi
    mv "$file.tmp" "$file"
}

mock_get_unit_state() {
    grep -F "$1=" "$MOCK_DIR/systemd.state" 2>/dev/null | head -n 1 | cut -d= -f2-
}

mock_reset_postconf() {
    cat >"$MOCK_DIR/postconf.state" <<EOF
compatibility_level = 3.6
mail_version = 3.8.6
queue_directory = ${TEST_TMP:-/tmp}/queue
relay_domains = hash:$MXB_MAPS_DIR/relay_domains
relay_recipient_maps = hash:$MXB_MAPS_DIR/relay_recipients
transport_maps = hash:$MXB_MAPS_DIR/transport
smtp_tls_policy_maps = hash:$MXB_MAPS_DIR/smtp_tls_policy
mynetworks = 127.0.0.0/8 [::1]/128
smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination
EOF
    # master.cf model: one entry per line, plus per-entry chroot fields.
    cat >"$MOCK_DIR/master.state" <<'EOF'
smtp/inet
smtp/unix
pickup/unix
uucp/unix
lmtp/unix
virtual/unix
relay/unix
EOF
    cat >"$MOCK_DIR/chroot.state" <<'EOF'
smtp/inet/chroot=y
smtp/unix/chroot=y
pickup/unix/chroot=n
EOF
}

mock_reset() {
    rm -rf "$MOCK_DIR" 2>/dev/null || true
    mkdir -p "$MOCK_DIR"
    : >"$MOCK_DIR/calls.log"
    : >"$MOCK_DIR/systemd.state"
    printf 'Status: inactive\n' >"$MOCK_DIR/ufw.state"
    mock_reset_postconf

    export MOCK_API_CODE=200
    export MOCK_GH_CODE=200
    export MOCK_GH_LATEST=1.0.0
    export MOCK_API_BAD_JSON=0
    export MOCK_API_EMPTY=0
    export MOCK_CURL_FAIL=0
    export MOCK_POSTMAP_FAIL=0
    export MOCK_RELOAD_FAIL=0
    export MOCK_APT_FAIL=0
    export MOCK_SYSTEMCTL_FAIL=0
    export MOCK_SYSTEMCTL_START_FAIL=""
    export MOCK_CORRUPT_ASSET=0
    export MOCK_GH_RATE_LIMIT=0
    export MOCK_POSTCONF_UNCONFIGURED=0
    export MOCK_POSTCONF_COMPAT=3.6
    export MOCK_NTPSYNC=yes
    export MOCK_POSTSCREEN_ACCESS=""
    export MOCK_RSPAMD_CONFIGTEST_FAIL=0
    export MOCK_RSPAMD_RESTART_FAIL=0
    export MOCK_RSPAMD_DOWN=0
}

mock_calls_contain() { grep -qF -- "$1" "$MOCK_DIR/calls.log"; }
mock_calls_count() {
    local n
    n=$(grep -cF -- "$1" "$MOCK_DIR/calls.log" 2>/dev/null) || true
    printf '%s' "${n:-0}"
}
mock_clear_calls() { : >"$MOCK_DIR/calls.log"; }

# ---------------------------------------------------------------------------
# curl
# ---------------------------------------------------------------------------
curl() {
    local out="" writeout="" url="" config=0 failmode=0 code=200 body="" src="" wo=""
    local -a positional=()
    while (( $# > 0 )); do
        case "$1" in
            -o|--output) out=${2:-}; shift 2 ;;
            -w|--write-out) writeout=${2:-}; shift 2 ;;
            -K|--config)
                [[ ${2:-} == "-" ]] && config=1
                shift 2
                ;;
            --cacert|--proto|--proto-redir|--connect-timeout|--max-time|--retry|--retry-delay|-H|--header|--max-redirs)
                shift 2
                ;;
            --silent|--show-error|--tlsv1.2|--compressed|--location)
                shift
                ;;
            --fail) failmode=1; shift ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    if [[ "$config" -eq 1 ]]; then
        local cfg
        cfg=$(cat)
        url=$(printf '%s\n' "$cfg" | sed -n 's/^url = "\(.*\)"$/\1/p' | head -n 1)
    fi
    if [[ -z "$url" && ${#positional[@]} -gt 0 ]]; then
        url=${positional[${#positional[@]} - 1]}
    fi

    mock_log "curl $url"

    if [[ "${MOCK_CURL_FAIL:-0}" == "1" ]]; then
        [[ -n "$out" ]] && : >"$out"
        if [[ -n "$writeout" ]]; then
            wo=$writeout
            wo=${wo//%\{http_code\}/000}
            wo=${wo//%\{time_total\}/0.000000}
            wo=${wo//%\{ssl_verify_result\}/0}
            printf '%s' "$wo"
        else
            printf '000'
        fi
        return 7
    fi

    case "$url" in
        *"/api/v1/get/domain/all"*)       code=${MOCK_API_CODE:-200}; src="$MOCK_FIXTURES/domains.json" ;;
        *"/api/v1/get/mailbox/all"*)      code=${MOCK_API_CODE:-200}; src="$MOCK_FIXTURES/mailboxes.json" ;;
        *"/api/v1/get/alias-domain/all"*) code=${MOCK_API_CODE:-200}; src="$MOCK_FIXTURES/alias_domains.json" ;;
        *"/api/v1/get/alias/all"*)        code=${MOCK_API_CODE:-200}; src="$MOCK_FIXTURES/aliases.json" ;;
        *api.github.com*)
            code=${MOCK_GH_CODE:-200}
            [[ "${MOCK_GH_RATE_LIMIT:-0}" == "1" ]] && code=403
            case "$url" in
                */releases/latest)
                    body="{\"tag_name\":\"v${MOCK_GH_LATEST:-1.0.0}\",\"name\":\"v${MOCK_GH_LATEST:-1.0.0}\"}"
                    ;;
                */releases/tags/*)
                    local tag=${url##*/tags/v}
                    body="{\"tag_name\":\"v${tag}\",\"name\":\"v${tag}\"}"
                    ;;
                */releases*)
                    body='[{"tag_name":"v9.9.9","published_at":"2026-01-01T00:00:00Z"},{"tag_name":"v1.0.0","published_at":"2025-12-01T00:00:00Z"}]'
                    ;;
                *)
                    code=404
                    body='{"message":"Not Found"}'
                    ;;
            esac
            ;;
        *github.com*/releases/download/v*)
            local rest ver asset
            rest=${url##*/releases/download/v}
            ver=${rest%%/*}
            asset=${rest#*/}
            src="$MOCK_RELEASE_DIR/$asset"
            [[ -f "$src" ]] || src="$MOCK_RELEASE_DIR-$ver/$asset"
            if [[ -f "$src" ]]; then
                code=200
                if [[ "${MOCK_CORRUPT_ASSET:-0}" == "1" && "$asset" == *.tar.gz ]]; then
                    cp "$src" "$out"
                    printf 'corrupt' >>"$out"
                    src=""
                fi
            else
                code=404
            fi
            ;;
        *)
            code=404
            body='{"message":"Not Found"}'
            ;;
    esac

    if [[ -n "$src" && -f "$src" ]]; then
        if [[ "$url" == *"/api/v1/get/"* ]]; then
            if [[ "${MOCK_API_EMPTY:-0}" == "1" ]]; then
                src=""
                body="{}"
            fi
            if [[ "${MOCK_API_BAD_JSON:-0}" == "1" ]]; then
                src=""
                body="{not json"
            fi
        fi
    fi

    if [[ -n "$src" && -f "$src" ]]; then
        if [[ -n "$out" ]]; then cp "$src" "$out"; else cat "$src"; fi
    elif [[ -n "$body" ]]; then
        if [[ -n "$out" ]]; then printf '%s' "$body" >"$out"; else printf '%s' "$body"; fi
    elif [[ -n "$out" && "$code" == "200" ]]; then
        : >"$out"
    fi

    if [[ -n "$writeout" ]]; then
        # Emulate the curl placeholders the scripts rely on, so their parsing is
        # exercised instead of being short-circuited by a fixed string.
        wo=$writeout
        wo=${wo//%\{http_code\}/$code}
        wo=${wo//%\{time_total\}/0.100000}
        wo=${wo//%\{ssl_verify_result\}/0}
        printf '%s' "$wo"
    fi
    if [[ "$failmode" -eq 1 && "$code" != "200" ]]; then
        return 22
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Postfix tools
# ---------------------------------------------------------------------------
postmap() {
    mock_log "postmap $*"
    local key="" dump=0 path=""
    while (( $# > 0 )); do
        case "$1" in
            -q) key=${2:-}; shift 2 ;;
            -s) dump=1; shift ;;
            *) path=$1; shift ;;
        esac
    done
    path=${path#hash:}
    [[ "${MOCK_POSTMAP_FAIL:-0}" == "1" ]] && return 1
    if [[ ! -f "$path" ]]; then
        printf 'postmap: open %s: No such file or directory\n' "$path" >&2
        return 1
    fi
    if [[ -n "$key" ]]; then
        local lookup_file
        lookup_file="$path"
        [[ -f "$path.db" ]] && lookup_file="$path.db"
        awk -v k="$key" 'tolower($1) == tolower(k) { sub(/^[^ \t]+[ \t]+/, ""); print; found = 1; exit } END { if (!found) exit 1 }' "$lookup_file"
        return
    fi
    if [[ "$dump" -eq 1 ]]; then
        cat "$path"
        return 0
    fi
    cp "$path" "$path.db"
}

postalias() { mock_log "postalias $*"; postmap "$@"; }

postconf() {
    mock_log "postconf $*"
    local state="$MOCK_DIR/postconf.state"
    local master="$MOCK_DIR/master.state"
    local chroots="$MOCK_DIR/chroot.state"
    local compat="${MOCK_POSTCONF_COMPAT:-3.6}"
    local default=0 short=0 mode="" param="" kv="" value=""
    local -a positional=()

    while (( $# > 0 )); do
        case "$1" in
            -e) mode=e; kv=${2:-}; shift 2 ;;
            -n) mode=n; shift ;;
            -M) mode=M; shift ;;
            -MX) mode=MX; shift ;;
            -F) mode=F; shift ;;
            -X) mode=X; shift ;;
            -d) default=1; shift ;;
            -h) short=1; shift ;;
            -c) shift 2 ;;
            *) positional+=("$1"); shift ;;
        esac
    done
    param=${positional[0]:-}

    # Mimic a postfix package installed with "No configuration": main.cf does
    # not exist, so reading a value fails and the built-in default is 0. The
    # installer restores main.cf, after which postconf works normally again.
    if [[ "${MOCK_POSTCONF_UNCONFIGURED:-0}" == "1" && -z "$mode" \
          && ! -f "${MXB_POSTFIX_ETC:-/etc/postfix}/main.cf" ]]; then
        compat=0
        (( default == 1 )) || return 1
    fi

    case "$mode" in
        e)
            local key val
            key=$(printf '%s' "$kv" | awk -F'=' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')
            val=$(printf '%s' "$kv" | awk -F'=' '{sub(/^[^=]*=/, ""); gsub(/^[ \t]+|[ \t]+$/, "", $0); print}')
            touch "$state"
            awk -v k="$key" -v v="$val" '
                BEGIN { done = 0 }
                { split($0, a, " = "); if (a[1] == k) { print k " = " v; done = 1 } else print }
                END { if (!done) print k " = " v }
            ' "$state" >"$state.tmp"
            mv "$state.tmp" "$state"
            return 0
            ;;
        X)
            local p
            for p in "${positional[@]}"; do
                [[ -n "$p" ]] || continue
                awk -v k="$p" -F' = ' '$1 != k' "$state" >"$state.tmp"
                mv "$state.tmp" "$state"
            done
            return 0
            ;;
        n) cat "$state"; return 0 ;;
        M)
            local entry
            while IFS= read -r entry; do
                [[ -n "$entry" ]] || continue
                if [[ -n "$param" && "$entry" != "$param" ]]; then
                    continue
                fi
                printf '%s  %s  n  -  y  -  -  %s\n' "${entry%%/*}" "${entry##*/}" "${entry##*/}"
            done <"$master"
            return 0
            ;;
        MX)
            local name
            for name in "${positional[@]}"; do
                [[ -n "$name" ]] || continue
                grep -vxF -- "$name" "$master" >"$master.tmp" 2>/dev/null || :
                mv "$master.tmp" "$master"
                grep -vxF -- "$name" "$chroots" >"$chroots.tmp" 2>/dev/null || :
                mv "$chroots.tmp" "$chroots"
            done
            return 0
            ;;
        F)
            local arg=${positional[0]:-} fkey fval
            [[ -n "$arg" ]] || return 1
            if [[ "$arg" == *"="* ]]; then
                fkey=${arg%%=*}
                fval=${arg#*=}
                awk -v k="$fkey" -v v="$fval" '
                    BEGIN { done = 0 }
                    { split($0, a, "="); if (a[1] == k) { print k "=" v; done = 1 } else print }
                    END { if (!done) print k "=" v }
                ' "$chroots" >"$chroots.tmp"
                mv "$chroots.tmp" "$chroots"
                return 0
            fi
            awk -v k="$arg" -F= '$1 == k { print; found = 1 } END { exit found ? 0 : 1 }' "$chroots"
            return
            ;;
    esac

    if (( default == 1 )); then
        case "$param" in
            compatibility_level) value=$compat ;;
            mail_version) value="3.8.6" ;;
            "") return 0 ;;
            *) value="" ;;
        esac
        if (( short == 1 )); then
            printf '%s\n' "$value"
        else
            printf '%s = %s\n' "$param" "$value"
        fi
        return 0
    fi

    if (( short == 1 )); then
        [[ -z "$param" ]] && return 0
        awk -F' = ' -v k="$param" '$1 == k { sub(/^[^=]*= */, ""); print; exit }' "$state"
        return 0
    fi
    return 0
}

postfix() {
    mock_log "postfix $*"
    case "${1:-}" in
        reload)
            [[ "${MOCK_RELOAD_FAIL:-0}" == "1" ]] && return 1
            return 0
            ;;
        status|check|start|stop|set-permissions) return 0 ;;
        *) return 0 ;;
    esac
}

postqueue() {
    mock_log "postqueue $*"
    case "${1:-}" in
        -j)
            [[ -n "${MOCK_QUEUE_JSONL:-}" && -f "$MOCK_QUEUE_JSONL" ]] && cat "$MOCK_QUEUE_JSONL"
            ;;
        -p)
            [[ -n "${MOCK_QUEUE_TEXT:-}" && -f "$MOCK_QUEUE_TEXT" ]] && cat "$MOCK_QUEUE_TEXT"
            ;;
        *) return 0 ;;
    esac
    return 0
}

newaliases() { mock_log "newaliases $*"; return 0; }

# ---------------------------------------------------------------------------
# systemd and system tools
# ---------------------------------------------------------------------------
systemctl() {
    mock_log "systemctl $*"
    [[ "${MOCK_SYSTEMCTL_FAIL:-0}" == "1" ]] && return 1
    local cmd=${1:-} unit
    shift || true
    case "$cmd" in
        daemon-reload) return 0 ;;
        enable|start)
            unit=${!#}
            if [[ "$cmd" == "start" && -n "${MOCK_SYSTEMCTL_START_FAIL:-}" \
                && "$unit" == "$MOCK_SYSTEMCTL_START_FAIL" ]]; then
                return 1
            fi
            if [[ "$cmd" == "enable" ]]; then
                mock_set_unit_state "$unit" enabled
            else
                mock_set_unit_state "$unit" active
            fi
            return 0
            ;;
        is-active)
            local state quiet=0 arg
            for arg in "$@"; do
                [[ "$arg" == "--quiet" || "$arg" == "-q" ]] && quiet=1
            done
            unit=${!#}
            state=$(mock_get_unit_state "$unit")
            [[ -n "$state" ]] || state="inactive"
            (( quiet == 1 )) || printf '%s\n' "$state"
            [[ "$state" == "active" ]]
            return
            ;;
        is-enabled)
            unit=${!#}
            local state
            state=$(mock_get_unit_state "$unit")
            [[ "$state" == "enabled" || "$state" == "active" ]]
            return
            ;;
        status) printf 'active (running)\n'; return 0 ;;
        list-timers)
            printf 'NEXT                        LEFT     LAST                        PASSED   UNIT                ACTIVATES\n'
            printf 'Wed 2026-01-01 00:15:00 UTC 1h left  Tue 2025-12-31 22:15:00 UTC 1h ago   mailcow-sync.timer  mailcow-sync.service\n'
            return 0
            ;;
        show) printf 'ActiveState=active\nNextElapseUSecRealtime=Wed 2026-01-01 00:15:00 UTC\n'; return 0 ;;
        cat) return 0 ;;
        --failed) return 0 ;;
        *) return 0 ;;
    esac
}

journalctl() {
    mock_log "journalctl $*"
    if [[ -s "$MOCK_JOURNAL" ]]; then
        cat "$MOCK_JOURNAL"
    else
        printf -- '-- No entries --\n'
    fi
    return 0
}

ss() { mock_log "ss $*"; printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port\nLISTEN 0 100 0.0.0.0:25 0.0.0.0:*\n'; }

free() { mock_log "free $*"; printf '               total        used        free\nMem:            2048         512        1024\n'; }

df() { mock_log "df $*"; printf 'Filesystem      Size  Used Avail Use%% Mounted on\n/dev/sda1        40G  8.0G   30G  22%% /\n'; }

timedatectl() {
    mock_log "timedatectl $*"
    case "$*" in
        *show*)
            case "$*" in
                *NTPSynchronized*) printf '%s\n' "${MOCK_NTPSYNC:-yes}" ;;
                *) printf 'NTPMessage={ "ServerName": "ntp.example.com", "OffsetUSec": 120 }\n' ;;
            esac
            return 0
            ;;
    esac
    printf 'System clock synchronized: %s\nNTP service: active\n' "${MOCK_NTPSYNC:-yes}"
}

openssl() {
    mock_log "openssl $*"
    case "$*" in
        *s_client*)
            printf 'CONNECTED(00000003)\n'
            if [[ "${MOCK_TLS_FAIL:-0}" == "1" ]]; then
                printf 'verify error:num=20:unable to get local issuer certificate\n'
                printf 'Verify return code: 20 (unable to get local issuer certificate)\n'
                return 1
            fi
            printf -- '-----BEGIN CERTIFICATE-----\nMIIBmockCertificate\n-----END CERTIFICATE-----\n'
            printf 'Verify return code: 0 (ok)\n'
            ;;
        *)
            if [[ "$*" == *"-checkhost"* && "${MOCK_CERT_HOST_MISMATCH:-0}" == "1" ]]; then
                printf 'Hostname does NOT match certificate\n' >&2
                return 1
            fi
            printf 'subject=CN = mail.example.com\n'
            printf 'issuer=C = US, O = Test CA, CN = Test CA\n'
            printf 'notBefore=Jan  1 00:00:00 2026 GMT\n'
            printf 'notAfter=Apr  1 00:00:00 2026 GMT\n'
            ;;
    esac
    return 0
}

getent() { mock_log "getent $*"; printf '203.0.113.10    mail.example.com\n'; }

needrestart() { mock_log "needrestart $*"; printf 'NEEDRESTART-VER: 3.5\n'; }

ufw() {
    mock_log "ufw $*"
    case "$*" in
        *"status"*)
            [[ "$*" == *"status"* && "$*" != *"--force"* ]] && cat "$MOCK_DIR/ufw.state"
            ;;
    esac
    if [[ "$*" == *"--force enable"* ]]; then
        printf 'Status: active\n' >"$MOCK_DIR/ufw.state"
    fi
    return 0
}

hostname() {
    mock_log "hostname $*"
    printf '%s\n' "${MOCK_FQDN:-mx2.example.com}"
}

dpkg() { mock_log "dpkg $*"; return 0; }

dpkg-query() {
    mock_log "dpkg-query $*"
    if [[ "$*" == *Status* ]]; then
        printf 'install ok installed\n'
    else
        printf 'postfix 3.8.6-1ubuntu0.1\n'
    fi
    return 0
}

apt-get() {
    mock_log "apt-get $*"
    if [[ "${MOCK_APT_FAIL:-0}" == "1" ]]; then
        printf 'E: Failed to fetch http://archive.ubuntu.com/ubuntu/pool/main/x/x.deb  503  Service Unavailable\n'
        return 100
    fi
    printf 'Hit:1 http://archive.ubuntu.com/ubuntu noble InRelease\n'
    printf 'Reading package lists... Done\n'
    printf '3 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n'
    printf 'Setting up postfix (3.8.6-1ubuntu0.1) ...\n'
    return 0
}

timeout() {
    mock_log "timeout $*"
    shift || true
    # diagnose.sh probes SMTP with `timeout N bash -c '... /dev/tcp/...'`.
    # Running that for real would open a socket to a black-holed address and
    # wait for the kernel timeout, so report an immediate timeout instead.
    case "$*" in
        *"/dev/tcp/"*) return 124 ;;
    esac
    "$@"
}

mock_cidr_lookup() {
    local address=$1 map=$2 path
    path=${map#cidr:}
    case "$path" in
        /opt/postfix/conf/*) path="$MAILCOW_DIR/data/conf/postfix/${path#/opt/postfix/conf/}" ;;
    esac
    [[ -r "$path" ]] || return 1
    awk -v ip="$address" '
        ($1 == ip || $1 == ip "/32" || $1 == ip "/128") && $2 == "permit" { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$path" || return 1
    printf 'permit'
}

mock_compose_exec() {
    local service=$1
    shift || true
    local command=${1:-}
    case "$service:$command" in
        postfix-mailcow:postconf)
            shift || true
            [[ "${1:-}" == "-h" ]] || return 0
            printf '%s\n' "${MOCK_POSTSCREEN_ACCESS:-permit_mynetworks, cidr:/opt/postfix/conf/custom_postscreen_whitelist.cidr, cidr:/opt/postfix/conf/postscreen_access.cidr, tcp:127.0.0.1:10027}"
            ;;
        postfix-mailcow:postmap)
            shift || true
            local address="" map=""
            while (( $# )); do
                case "$1" in
                    -q) address=${2:-}; shift 2 ;;
                    *) map=${1:-}; shift ;;
                esac
            done
            mock_cidr_lookup "$address" "$map"
            ;;
        postfix-mailcow:postfix)
            if [[ "$*" == *reload* && "${MOCK_RELOAD_FAIL:-0}" == "1" ]]; then
                return 1
            fi
            return 0
            ;;
        rspamd-mailcow:rspamadm)
            shift || true
            case "${1:-}" in
                configtest)
                    if [[ "${MOCK_RSPAMD_CONFIGTEST_FAIL:-0}" == "1" ]]; then
                        printf 'cannot parse the configuration\n' >&2
                        return 1
                    fi
                    return 0
                    ;;
                configdump)
                    if [[ -r "$MAILCOW_DIR/data/conf/rspamd/local.d/settings.conf" ]]; then
                        cat "$MAILCOW_DIR/data/conf/rspamd/local.d/settings.conf"
                    fi
                    return 0
                    ;;
                control)
                    [[ "${MOCK_RSPAMD_DOWN:-0}" == "1" ]] && return 1
                    return 0
                    ;;
            esac
            return 0
            ;;
    esac
    return 0
}

docker() {
    mock_log "docker $*"
    local command=${1:-}
    shift || true
    case "$command" in
        compose)
            local sub=${1:-}
            shift || true
            case "$sub" in
                version) return 0 ;;
                ps)
                    local service=""
                    while (( $# )); do
                        case "$1" in
                            -q|--quiet) shift ;;
                            *) service=${1:-}; shift ;;
                        esac
                    done
                    [[ -n "$service" ]] && printf 'cid-%s\n' "$service"
                    return 0
                    ;;
                exec)
                    [[ "${1:-}" == "-T" ]] && shift
                    local service=${1:-}
                    shift || true
                    mock_compose_exec "$service" "$@"
                    return $?
                    ;;
                restart)
                    local service=${1:-}
                    if [[ "${MOCK_RSPAMD_RESTART_FAIL:-0}" == "1" && "$service" == "rspamd-mailcow" ]]; then
                        return 1
                    fi
                    return 0
                    ;;
            esac
            return 0
            ;;
        inspect)
            [[ "${1:-}" == "-f" ]] && shift 2
            local cid=${1:-}
            case "$cid" in
                cid-rspamd-mailcow)
                    printf '/etc/rspamd/local.d=%s\n' "$MAILCOW_DIR/data/conf/rspamd/local.d"
                    ;;
                *)
                    printf '/opt/postfix/conf=%s\n' "$MAILCOW_DIR/data/conf/postfix"
                    printf '/etc/ssl/mail=%s\n' "$MAILCOW_DIR/data/assets/ssl"
                    ;;
            esac
            return 0
            ;;
    esac
    return 0
}

export -f mock_log mock_set_unit_state mock_get_unit_state mock_reset_postconf
export -f mock_cidr_lookup mock_compose_exec
export -f curl postmap postalias postconf postfix postqueue newaliases
export -f systemctl journalctl ss free df timedatectl openssl getent needrestart ufw hostname
export -f dpkg dpkg-query apt-get timeout docker
