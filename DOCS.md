# mx-backup-mailcow — reference

Lookup material: where files live, which configuration keys exist, what each
flag does, what the synchronization writes into the Postfix maps, and the checks
that prove recipient validation and queue recovery work.

Installing and checking health are in [`OPERATIONS.md`](OPERATIONS.md); sending a
patch and cutting a release are in [`CONTRIBUTING.md`](CONTRIBUTING.md) and
[`MAINTAINER.md`](MAINTAINER.md). Each fact appears in exactly one document; the
others link here.

## Runtime layout

```text
/etc/mailcow-backup-mx/config                  credentials and settings (0600)
/etc/postfix/mailcow-backup-mx/                generated maps + .db indexes
/etc/postfix/tls/<hostname>.{crt,key}          inbound TLS copy readable by postfix
/etc/postfix/main.cf.pre-mx-backup-mailcow     original main.cf backup
/etc/systemd/system/mailcow-sync.{service,timer}
/etc/logrotate.d/mailcow-backup-mx
/opt/mx-backup-mailcow/                        application (bin, units, docs)
/opt/mx-backup-mailcow/share/mailcow/          script to run on the Mailcow host
/usr/local/sbin/{sync-mailcow,mx-update,mx-diagnose,mx-update-scripts}
/var/lib/mailcow-backup-mx/{cache,state,run,tmp}
/var/backups/mx-backup-mailcow/                map and application snapshots
/var/log/mailcow-backup-mx/                    logs and diagnostics
```

The source repository layout is different and lives in
[`MAINTAINER.md`](MAINTAINER.md#repository-layout).

## Configuration

**File:** `/etc/mailcow-backup-mx/config` — owner `root`, mode `0600`. The file
is sourced by the scripts, so shell quoting applies. `install.sh` rewrites the
managed keys and preserves comments and additional lines.

| Key                       | Default        | Description                                                         |
| ------------------------- | -------------- | ------------------------------------------------------------------- |
| `BACKUP_MX_HOSTNAME`      | `hostname -f`  | Postfix identity; must be a FQDN with matching A/AAAA and PTR       |
| `MAILCOW_HOST`            | —              | Mailcow API hostname                                                |
| `MAILCOW_API_KEY`         | —              | Read-only API key                                                   |
| `MAILCOW_API_CA_FILE`     | empty          | Optional private CA bundle                                          |
| `MAILCOW_PRIMARY_IP`      | —              | Primary Mailcow IP                                                  |
| `MAILCOW_PRIMARY_PORT`    | `25`           | Primary SMTP port                                                   |
| `SMTP_TLS_MODE`           | `secure`       | `secure` (verified) or `may` (opportunistic, unauthenticated)       |
| `SMTP_TLS_MATCH_HOSTNAME` | `MAILCOW_HOST` | Certificate name required by `secure`                               |
| `SMTPD_TLS_CERT_FILE`     | auto (LE)      | Certificate chain offered to inbound MTAs                           |
| `SMTPD_TLS_KEY_FILE`      | auto (LE)      | Private key for `SMTPD_TLS_CERT_FILE`                               |
| `OPERATIONAL_MAIL_TO`     | empty          | Forward root/postmaster/abuse mail here; empty discards it          |
| `EXCLUDE_DOMAINS`         | empty          | Space-separated domains to skip                                     |
| `RELAX_AFTER_DAYS`        | `7`            | Days without API sync before accepting all recipients; `0` disables |
| `QUEUE_LIFETIME`          | `7d`           | Maximum time mail is kept while the primary is down                 |
| `MESSAGE_SIZE_LIMIT`      | `104857600`    | Maximum message size (100 MB)                                       |

All paths can be overridden with environment variables for staging or tests:
`MXB_ETC`, `MXB_CONFIG_FILE`, `MXB_MAPS_DIR`, `MXB_STATE_DIR`, `MXB_LOG_DIR`,
`MXB_BACKUP_DIR`, `MXB_INSTALL_DIR`, `MXB_BIN_DIR`, `MXB_SYSTEMD_DIR`,
`MXB_LOGROTATE_DIR`, `MXB_POSTFIX_ETC`, `MXB_SSH_DIR`, `MXB_OS_RELEASE`,
`MXB_REBOOT_MARKER`, `MXB_REBOOT_PKGS`, `MXB_CA_BUNDLE`, `MXB_LETSENCRYPT_DIR`,
`MXB_RENEWAL_HOOK_DIR`, `MXB_CLOCK_WAIT_SECONDS`, `MXB_SKIP_CLOCK_CHECK`,
`MXB_SKIP_SMTP_SELFTEST`, `MXB_SKIP_AUTO_TLS`, `MXB_SKIP_ROOT_CHECK`.

### Postfix

`install.sh` configures Postfix with `postconf -e`; the authoritative list is the
`settings` array in `configure_postfix()` in [`install.sh`](install.sh). The keys
cover:

- destinations, interfaces and `mynetworks`;
- the four synchronized maps plus `aliases`;
- relay and recipient restrictions, reject codes and `recipient_delimiter`;
- queue lifetime, backoff, warning delay and size limits;
- inbound TLS (when a certificate is configured) and outbound TLS policy.

Three provisioning steps are verification-driven rather than cosmetic:

- **Identity.** `$myhostname` must be a FQDN. The installer refuses a hostname
  without a dot (use `--hostname` or `hostnamectl set-hostname`) because Postfix
  derives the HELO name and every DSN sender from it; a single label is rejected
  by strict receivers and cannot hold a certificate.
- **Inbound TLS.** The chain and key are copied to
  `/etc/postfix/tls/<hostname>.{crt,key}` (`root:postfix`, mode `0644`/`0640`)
  because Postfix reads the key as the unprivileged `postfix` user, which cannot
  read a certbot live directory. When no certificate is configured, the installer
  requests one from Let's Encrypt for the Postfix hostname. When the source is
  under `/etc/letsencrypt`, a deploy hook in
  `/etc/letsencrypt/renewal-hooks/deploy/` refreshes the copy and reloads
  Postfix on renewal. Without a certificate, port 25 runs without STARTTLS and
  the installer says so.
- **Map visibility.** A chrooted Postfix process resolves paths inside
  `$queue_directory`, so a map outside the jail is invisible to it. If the
  service runs chrooted and the maps are not present inside the jail, the
  installer sets `chroot=n` for `smtp/inet` and `smtp/unix` (the upstream
  default) and logs why.

The unused `uucp`, `lmtp` and `virtual` service entries are removed from
`master.cf`: this host delivers locally to nobody and executes no external
mailer. `relay` and `pickup` stay.

Local operational mail is forwarded to `OPERATIONAL_MAIL_TO` when set, and
otherwise discarded (`/dev/null`): an `aliases` map covers `postmaster`, `root`,
`mailer-daemon`, `double-bounce`, `nobody`, `hostmaster`, `webmaster`, `abuse`
and `security`. The map is in `aliases(5)` form and is indexed with `postalias`,
not `postmap` (the latter warns that the file "is this an alias file?"). The four
synchronized maps are seeded empty, so Postfix can start before the first
synchronization.

The original `main.cf` is kept once as `main.cf.pre-mx-backup-mailcow`. When
the postfix package was installed with the "No configuration" mailer type and
ships no `/etc/postfix/main.cf` or `master.cf`, the installer restores both from
the package templates (`/usr/share/postfix/main.cf.debian` and
`master.cf.dist`) before writing any setting. A `compatibility_level` below `2`
is raised to `3.6`: levels `0` and `1` select Postfix's backwards-compatible
legacy defaults, which this configuration does not intend (Postfix reports the
compiled-in default `0` when `main.cf` does not set one).

### TLS

Two independent hops are configured:

| Hop                    | Mechanism                                    | Default                                                   |
| ---------------------- | -------------------------------------------- | --------------------------------------------------------- |
| sender → this MX (25)  | `smtpd_tls_security_level=may` + certificate | STARTTLS when a certificate is configured, otherwise none |
| this MX → primary (25) | `smtp_tls_policy_maps` (`smtp_tls_policy`)   | `secure match=<MAILCOW_HOST>`: certificate must verify    |

Inbound: `install.sh` uses `/etc/letsencrypt/live/<hostname>/{fullchain,privkey}.pem`
when present, or the paths given with `--inbound-tls-cert`/`--inbound-tls-key`.
When neither exists, it installs certbot if necessary and requests a certificate
with the HTTP-01 standalone challenge. The hostname must resolve to this server
and TCP/80 must be reachable; the firewall keeps 80 open for renewals once a
Let's Encrypt certificate is in use. A failed request does not abort the
installation: port 25 is configured without STARTTLS and the warning prints the
manual retry command. The chain and key are then copied to `/etc/postfix/tls/`.

The deploy hook at `/etc/letsencrypt/renewal-hooks/deploy/mx-backup-mailcow-tls`
copies renewed material and reloads Postfix, so no manual step is needed at
renewal. Certificates from another CA are staged the same way but must be
renewed by whatever issued them; re-run `install.sh` afterwards. To skip
automatic issuance on a host that obtains certificates another way, set
`MXB_SKIP_AUTO_TLS=1`. `--no-inbound-tls` applies only to the run that uses it;
add `MXB_SKIP_AUTO_TLS=1` to `/etc/mailcow-backup-mx/config` to skip issuance on
later runs. An existing certificate is still adopted, so repeat
`--no-inbound-tls` (or remove the lineage) if STARTTLS must never be offered.

The ACME account is registered without a contact address, and Let's Encrypt no
longer sends expiry reminders. Check that `certbot.timer` is active, run
`certbot renew --dry-run` periodically (port 80 must be available), and monitor
the certificate dates printed by `mx-diagnose`.

Outbound: `SMTP_TLS_MODE=secure` is the default and is only accepted when the
primary's certificate verifies for `SMTP_TLS_MATCH_HOSTNAME`; `may` accepts an
unverified (or absent) certificate and logs that the hop is unauthenticated.
`mx-diagnose` reports both hops and the effective policy line.

```bash
# inbound: expect a certificate and "Verify return code: 0"
openssl s_client -starttls smtp -connect 127.0.0.1:25 -servername mx2.example.com </dev/null
# outbound: the policy that is actually applied
cat /etc/postfix/mailcow-backup-mx/smtp_tls_policy
```

## Scripts and flags

All scripts are standalone Bash and can be run directly from
`/opt/mx-backup-mailcow/bin/` or through the symlinks in `/usr/local/sbin`:

| Command             | Installed script                    |
| ------------------- | ----------------------------------- |
| `sync-mailcow.sh`   | `/usr/local/sbin/sync-mailcow`      |
| `update.sh`         | `/usr/local/sbin/mx-update`         |
| `diagnose.sh`       | `/usr/local/sbin/mx-diagnose`       |
| `update-scripts.sh` | `/usr/local/sbin/mx-update-scripts` |

### `install.sh`

Provisions the server. Supports interactive and non-interactive operation,
bootstraps releases, validates checksums and is idempotent. `--local-dir DIR`
installs a checkout or a downloaded tree without contacting GitHub.

| Option                        | Description                                                             |
| ----------------------------- | ----------------------------------------------------------------------- |
| `--mailcow-host HOST`         | Mailcow API hostname                                                    |
| `--primary-ip IP`             | Primary Mailcow IP used for delivery                                    |
| `--api-key KEY`               | API key inline (visible in `ps`; prefer stdin)                          |
| `--api-key-stdin`             | Read the API key from standard input                                    |
| `--ca-file PATH`              | Private CA bundle for the Mailcow API certificate                       |
| `--smtp-tls-mode secure\|may` | Outbound TLS policy (default `secure`)                                  |
| `--tls-match HOSTNAME`        | Certificate name for `secure` mode (default: `MAILCOW_HOST`)            |
| `--hostname FQDN`             | Postfix identity (default: `hostname -f`)                               |
| `--inbound-tls-cert PATH`     | Certificate chain offered to inbound MTAs (skips the automatic request) |
| `--inbound-tls-key PATH`      | Private key for `--inbound-tls-cert`                                    |
| `--no-inbound-tls`            | Install without STARTTLS and skip the automatic certificate request     |
| `--operational-mail ADDR`     | Forward root/postmaster mail to this address                            |
| `--release VERSION`           | Install a specific release instead of the latest                        |
| `--local-dir DIR`             | Install from a local checkout/release (offline, no release needed)      |
| `--sha256 HEX`                | Verify the installer file before running                                |
| `--config FILE`               | Read values from a shell-style file                                     |
| `--non-interactive`           | Never prompt                                                            |
| `--yes`                       | Skip the confirmation question                                          |
| `--skip-upgrade`              | Do not upgrade existing Ubuntu packages                                 |
| `--skip-initial-sync`         | Do not run the first synchronization                                    |
| `--no-firewall`               | Do not configure UFW                                                    |
| `--force`                     | Proceed on otherwise fatal warnings                                     |

Re-running the installer is safe; what it preserves and how it behaves when the
first synchronization fails is in [`OPERATIONS.md`](OPERATIONS.md#installation).

Before it changes anything the installer verifies, and refuses to continue if it
cannot:

1. the clock is synchronized (`timedatectl show -p NTPSynchronized`), because TLS
   validity and queue lifetimes depend on it;
2. the primary presents a certificate valid for `SMTP_TLS_MATCH_HOSTNAME` on the
   configured port (in `secure` mode), because every queued message would
   otherwise be deferred;
3. after the first synchronization, a local SMTP dialogue accepts a synchronized
   recipient and rejects an unknown one, which proves that the running `smtpd`
   can read `relay_recipients` (a chrooted `smtpd` cannot read a map outside the
   jail) and that recipient validation is active.

### `sync-mailcow.sh`

Fetches domains, alias domains, mailboxes and aliases from the Mailcow API and
regenerates the maps.

```bash
sudo sync-mailcow.sh                  # normal run (also used by the timer)
sudo sync-mailcow.sh --dry-run        # build, validate, print a summary
sudo sync-mailcow.sh --force          # override safety checks
sudo sync-mailcow.sh --allow-empty    # accept a Mailcow with no active domains
sudo sync-mailcow.sh --no-reload      # install maps without reloading Postfix
sudo sync-mailcow.sh --rollback       # restore the latest map snapshot
sudo sync-mailcow.sh --rollback 20261114T201500Z-1234
```

Behaviour:

- **API failures:** falls back to the cache; if no cache exists, exits `1` and
  leaves the maps untouched.
- **Validation:** rejects malformed domains/addresses, empty responses and
  suspicious count drops. `--force` bypasses the drop protection and skips
  invalid entries.
- **Atomicity:** maps are built and indexed in
  `/etc/postfix/mailcow-backup-mx/.build.<pid>/`, then moved into place.
  The previous maps are snapshotted to
  `/var/backups/mx-backup-mailcow/maps-<timestamp>-<pid>/` (last five kept).
- **Reload:** only when a map or its `.db` index changed. If the reload fails, the snapshot is
  restored and a second reload is attempted; the script exits `1`.
- **Cache:** the normalized API response is stored in
  `/var/lib/mailcow-backup-mx/cache/` and reused during outages.
- **Relaxation:** if the API has been unavailable for `RELAX_AFTER_DAYS` days,
  every hosted domain accepts all recipients (`@domain` wildcards). The state
  reports `relaxed: true` and a critical log line is written. The next
  successful API sync restores strict validation.
- **Locking:** an atomic lock in `/var/lib/mailcow-backup-mx/run/` prevents
  overlapping runs; stale locks are detected by PID.
- **Secrets:** the API key is passed to curl through stdin, never argv or logs.

### `update.sh`

Updates Ubuntu packages independently of the application.

```bash
sudo mx-update            # apt-get update + upgrade --with-new-pkgs
sudo mx-update --dry-run  # simulate
```

It never performs a distribution upgrade, never reboots, and lets
`needrestart` restart services whose libraries were updated (never a reboot).
A reboot requirement is recorded in
`/var/lib/mailcow-backup-mx/state/update-state.json` and printed but not
executed. Exit status is `1` if apt reported failures.

### `diagnose.sh`

Strictly read-only. Produces an AI-ready Markdown report. It never changes
configuration, restarts services, flushes the queue, reads message bodies or
contacts an AI service. Credentials, API keys, private key blocks and
password-like values are redacted; email local parts in logs and the queue are
masked while domains remain visible. The report file is written with mode
`0600` and is safe to hand to a colleague or an AI assistant.

```bash
sudo mx-diagnose                 # summary, then the report path (last line)
sudo mx-diagnose --stdout        # report on stdout, summary on stderr
sudo mx-diagnose --out /root --lines 400
```

The terminal summary covers Postfix, queue length, the sync timer, last
synchronization, domains/mailboxes, inbound/outbound TLS, queue disk and a plain
`healthy`/`needs attention` verdict. It is for operators who do not read the full
report; the report remains the evidence.

The report opens with an analysis prompt, then these sections:

| Section                            | What to look at first                                                  |
| ---------------------------------- | ---------------------------------------------------------------------- |
| 1. System                          | disk and memory pressure, clock state, failed units                    |
| 2. Postfix                         | version, inbound TLS, chroot/map visibility, RCPT probe, queue         |
| 3. Mailcow synchronization         | last attempt/success, counts, cache age, map consistency, relaxed flag |
| 4. Connectivity                    | API, SMTP and TLS results per address family, certificate expiry       |
| 5. Security posture                | file modes, exposed ports, firewall                                    |
| 6. Application version and updates | installed version, last package update, pending reboot                 |
| 7. Recent system errors            | journal and install log excerpts                                       |

It also covers system resources, listening sockets, effective Postfix
configuration, map and timer history, and recent sanitized logs. How to read it
as an operator is in
[`OPERATIONS.md`](OPERATIONS.md#check-the-health-of-the-server).

### `update-scripts.sh`

Installs or updates the application from public GitHub Releases, without a
token. It requires a published release, so it cannot be used before the first
release exists.

```bash
sudo mx-update-scripts --check              # compare installed vs latest
sudo mx-update-scripts                      # update to the latest release
sudo mx-update-scripts --release 1.2.3      # install a specific version
sudo mx-update-scripts --release 1.2.3 --force   # allow a downgrade
sudo mx-update-scripts --list               # ten most recent releases
sudo mx-update-scripts --dry-run            # download and verify only
sudo mx-update-scripts --rollback           # restore the most recent backup
sudo mx-update-scripts --rollback 1.1.0     # restore a specific version
```

Safety properties:

- Downloads `mx-backup-mailcow-<version>.tar.gz` and `SHA256SUMS`, verifies the
  archive checksum, rejects unsafe archive paths, verifies the inner per-file
  manifest, checks that `VERSION` matches the requested release, and runs
  `bash -n` (plus `shellcheck -S error` when available).
- Backs up the current `/opt/mx-backup-mailcow` tree under
  `/var/backups/mx-backup-mailcow/app-<timestamp>-<version>/` (last five kept).
- Swaps the directory, reinstalls changed unit files, runs `daemon-reload` only
  when units changed, and re-runs the new updater in verification mode before
  reporting success. A failed verification restores the backup automatically.
- Never touches `/etc/mailcow-backup-mx`, Postfix maps, the mail queue or logs,
  and never reloads or restarts Postfix.
- The GitHub API is used without authentication; the documented rate limit may
  require waiting or using `--release`.

## Synchronization and maps

### Map files

The four synchronized maps are Postfix `hash:` maps: tab-separated
`key<TAB>value`, one entry per line, indexed by `postmap`. `sync-mailcow.sh`
writes them; edit one by hand only to repair a broken server, because the next
synchronization rewrites it. The `aliases` map in the same directory is written
by `install.sh` in `aliases(5)` form (`name: value`), is never synchronized and
is indexed with `postalias`. After any manual edit, rebuild the index and reload
Postfix:

```bash
sudo postmap hash:/etc/postfix/mailcow-backup-mx/relay_recipients
sudo postalias hash:/etc/postfix/mailcow-backup-mx/aliases
sudo postfix reload
```

| File               | Entry                                                 | Meaning                                                       |
| ------------------ | ----------------------------------------------------- | ------------------------------------------------------------- |
| `relay_domains`    | `example.com<TAB>OK`                                  | domain is relayed                                             |
| `relay_recipients` | `alice@example.com<TAB>OK`                            | exact recipient accepted                                      |
| `relay_recipients` | `@example.com<TAB>OK`                                 | every recipient of the domain (see [Recipients](#recipients)) |
| `transport`        | `example.com<TAB>smtp:[203.0.113.10]:25`              | delivery target is the primary IP, never MX                   |
| `smtp_tls_policy`  | `[203.0.113.10]:25<TAB>secure match=mail.example.com` | authenticated TLS to the primary (default)                    |
| `smtp_tls_policy`  | `[203.0.113.10]:25<TAB>may`                           | opportunistic, unauthenticated TLS                            |

Every relay domain must have a transport entry: without one, Postfix falls back
to MX resolution, which points back at this host, and mail loops. The
synchronization refuses to publish such a map, and `mx-diagnose` reports the
difference between the two maps.

Postfix is reloaded only when a map or its `.db` index changed.

### Domains

All active Mailcow domains are relay domains and are routed to the primary IP.
Alias domains are added as relay domains because they forward every local part
to their target domain. Inactive domains and targets are skipped.
`EXCLUDE_DOMAINS` removes domains explicitly.

### Recipients

| Mailcow object                               | Generated entry    |
| -------------------------------------------- | ------------------ |
| Active mailbox                               | `user@domain OK`   |
| Active alias                                 | `alias@domain OK`  |
| Catch-all alias (`@domain` / `is_catch_all`) | `@domain OK`       |
| Alias domain                                 | `@alias-domain OK` |
| `relay_all_recipients=1`                     | `@domain OK`       |

Postfix's recipient lookup tries the full address, then the address with the
`recipient_delimiter` extension removed, then the `@domain` wildcard. As a
result, `user+newsletter@domain` is accepted whenever `user@domain` exists, and
no per-tag entries are needed.

### Failure handling

| Situation                 | Result                                                    |
| ------------------------- | --------------------------------------------------------- |
| HTTP 401/403              | Log explains the key/IP allowlist; maps untouched; exit 1 |
| HTTP 5xx / timeout        | Cache fallback; maps rebuilt if needed; exit 0 (degraded) |
| Invalid JSON              | Abort; maps untouched; exit 1                             |
| Empty domains             | Abort unless `--allow-empty`                              |
| Domains but no recipients | Abort unless `--force`                                    |
| Population drop > 50%     | Abort unless `--force`                                    |
| `postmap` failure         | Abort; maps untouched                                     |
| Postfix reload failure    | Restore snapshot, retry reload, exit 1                    |
| No cache and no API       | Abort; maps untouched; exit 1                             |

### State and logs

| Path                                                         | Contents                                         |
| ------------------------------------------------------------ | ------------------------------------------------ |
| `/var/lib/mailcow-backup-mx/state/sync-state.json`           | Last attempt/success, source, counts, relaxation |
| `/var/lib/mailcow-backup-mx/cache/*.json`                    | Normalized API data                              |
| `/var/lib/mailcow-backup-mx/state/update-state.json`         | Last Ubuntu update result                        |
| `/var/lib/mailcow-backup-mx/state/update-scripts-state.json` | Last application update result                   |
| `/var/log/mailcow-backup-mx/sync.log`                        | Synchronization log                              |
| `/var/log/mailcow-backup-mx/update.log`                      | Package update log                               |
| `/var/log/mailcow-backup-mx/install.log`                     | Installation log                                 |
| `/var/log/mailcow-backup-mx/diagnostics/`                    | Health reports                                   |

Logs are rotated weekly, eight files kept, compressed, by
`/etc/logrotate.d/mailcow-backup-mx`.

## Mailcow-side allowlist

The backup MX relays mail for arbitrary senders, so Mailcow sees every queued
message as coming from the backup MX address. Two Mailcow components therefore
need to know that address:

| Layer      | File (host path)                                     | Change                                                  |
| ---------- | ---------------------------------------------------- | ------------------------------------------------------- |
| postscreen | `data/conf/postfix/custom_postscreen_whitelist.cidr` | `ADDR/32<TAB>permit`, so greet/DNSBL delays are skipped |
| rspamd     | `data/conf/rspamd/local.d/settings.conf`             | `greylist = null` for that address only                 |

The script that applies them is shipped at
`/opt/mx-backup-mailcow/share/mailcow/allowlist-backup-mx.sh` and runs on the
**Mailcow host** (it drives `docker compose`):

```bash
# first run; the address list is saved in /etc/mailcow-backup-mx-allowlist.conf
sudo bash allowlist-backup-mx.sh --ip 203.0.113.20

# after "apt upgrade" and ./update.sh: repair drift, no-op when nothing changed
sudo bash allowlist-backup-mx.sh

# verify only; exit 1 on drift, 0 when everything matches
sudo bash allowlist-backup-mx.sh --check

# undo everything
sudo bash allowlist-backup-mx.sh --remove
```

Properties, by design:

- **Sparse edits.** Each change is a marker-delimited block. Existing entries
  and comments in the postscreen file survive, and both files are rewritten
  only when their content differs.
- **Nothing tracked is touched.** Both files are included by Mailcow but are not
  shipped in the `mailcow-dockerized` git checkout, so `./update.sh` has no
  conflict with them. A Mailcow update can still revert them, which is why the
  script is re-run afterwards; `--check` reports that drift.
- **Discovery, not hardcoding.** The postscreen file is taken from
  `postconf -h postscreen_access_list` inside `postfix-mailcow`, and container
  paths are translated to host paths through the container's bind mounts. If a
  Mailcow release removes the `custom_postscreen_whitelist.cidr` reference, the
  script refuses to edit anything and says so.
- **Validation before activation.** The postscreen entry is looked up with
  `postmap -q` inside the container (it must resolve to `permit`), `rspamadm
configtest` must pass, and the new rule must appear in `rspamadm configdump
settings`. On any failure the previous files are restored and Postfix/rspamd
  are returned to that state.
- **Minimal trust.** Only greylisting is disabled for the address; spam,
  virus, DKIM, SPF and DMARC checks still run. `want_spam` and group disabling
  are never used.
- **Undo and audit.** Changed files are copied to
  `/var/backups/mailcow-backup-mx-allowlist/<timestamp>/` (last ten kept), and
  `--remove` deletes the blocks and the saved address list.

`rspamd` reloads maps dynamically (`rspamadm control reload`) but `local.d`
configuration is core configuration, so the script restarts `rspamd-mailcow`
(seconds; Postfix queues mail meanwhile) and waits for the control socket to
answer. Postfix is reloaded, not restarted.

## Verification checks

These checks require a lab or a maintenance window. They prove that recipient
validation and queue recovery work on the deployed server; the offline test
suite covers the same logic without an MTA.

### Recipient validation

From an external host:

```bash
# Known recipient: expect 250
swaks --to alice@example.com --server mx2.example.com --quit-after RCPT

# Plus addressing: expect 250
swaks --to alice+test@example.com --server mx2.example.com --quit-after RCPT

# Unknown recipient: expect 550
swaks --to nobody@example.com --server mx2.example.com --quit-after RCPT

# Unrelated domain: expect 550/554 (not a relay domain)
swaks --to user@gmail.com --server mx2.example.com --quit-after RCPT
```

The same exchange with `telnet` or `openssl s_client`:

```text
EHLO test.local
MAIL FROM:<sender@example.net>
RCPT TO:<alice@example.com>
DATA
Subject: backup mx test

test
.
QUIT
```

### Queue recovery

1. Stop Postfix on the primary (or block TCP/25).
2. Send a message to a valid recipient on a hosted domain.
3. `postqueue -p` shows one deferred message.
4. Restore the primary.
5. Within 5–15 minutes the queue empties; or run `sudo postqueue -f`.
6. Confirm the message in the recipient's mailbox.

Because no MTA is started during development, recipient acceptance is also
verified against a simulator that implements the documented Postfix lookup
order; the manual SMTP checks above are the confirmation before production use.
