# mx-backup-mailcow — reference

Lookup material: where files live, which configuration keys exist, what each
flag does, and what the synchronization writes into the Postfix maps.

Nothing here is a procedure. Installing, checking health, deploying by hand,
sending a patch and cutting a release are in
[`README.md`](README.md), [`MANUAL-SETUP.md`](MANUAL-SETUP.md),
[`CONTRIBUTING.md`](CONTRIBUTING.md) and [`MAINTAINER.md`](MAINTAINER.md)
respectively. Each fact appears in exactly one document; the others link here.

## Runtime layout

```text
/etc/mailcow-backup-mx/config                  credentials and settings (0600)
/etc/postfix/mailcow-backup-mx/                generated maps + .db indexes
/etc/postfix/main.cf.pre-mx-backup-mailcow     original main.cf backup
/etc/systemd/system/mailcow-sync.{service,timer}
/etc/logrotate.d/mailcow-backup-mx
/opt/mx-backup-mailcow/                        application (bin, units, docs)
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

| Key                       | Default     | Description                                                         |
| ------------------------- | ----------- | ------------------------------------------------------------------- |
| `MAILCOW_HOST`            | —           | Mailcow API hostname                                                |
| `MAILCOW_API_KEY`         | —           | Read-only API key                                                   |
| `MAILCOW_API_CA_FILE`     | empty       | Optional private CA bundle                                          |
| `MAILCOW_PRIMARY_IP`      | —           | Primary Mailcow IP                                                  |
| `MAILCOW_PRIMARY_PORT`    | `25`        | Primary SMTP port                                                   |
| `SMTP_TLS_MODE`           | `may`       | `may` (opportunistic) or `secure`                                   |
| `SMTP_TLS_MATCH_HOSTNAME` | empty       | Certificate name required by `secure`                               |
| `EXCLUDE_DOMAINS`         | empty       | Space-separated domains to skip                                     |
| `RELAX_AFTER_DAYS`        | `7`         | Days without API sync before accepting all recipients; `0` disables |
| `QUEUE_LIFETIME`          | `7d`        | Maximum time mail is kept while the primary is down                 |
| `MESSAGE_SIZE_LIMIT`      | `104857600` | Maximum message size (100 MB)                                       |

All paths can be overridden with environment variables for staging or tests:
`MXB_ETC`, `MXB_CONFIG_FILE`, `MXB_MAPS_DIR`, `MXB_STATE_DIR`, `MXB_LOG_DIR`,
`MXB_BACKUP_DIR`, `MXB_INSTALL_DIR`, `MXB_BIN_DIR`, `MXB_SYSTEMD_DIR`,
`MXB_LOGROTATE_DIR`, `MXB_POSTFIX_ETC`, `MXB_SSH_DIR`, `MXB_OS_RELEASE`,
`MXB_REBOOT_MARKER`, `MXB_REBOOT_PKGS`, `MXB_CA_BUNDLE`, `MXB_SKIP_ROOT_CHECK`.

### Postfix

The installer sets 43 keys with `postconf -e`. The complete list, the command
that sets each one, the aliases that discard local operational mail, and the
map seed files are in
[`MANUAL-SETUP.md`](MANUAL-SETUP.md#step-5--postfix). They cover:

- destinations, interfaces and `mynetworks`;
- the four synchronized maps plus `aliases`;
- relay and recipient restrictions, reject codes and `recipient_delimiter`;
- queue lifetime, backoff, warning delay and size limits;
- TLS security level, protocols and CA bundle.

The original `main.cf` is kept once as `main.cf.pre-mx-backup-mailcow`. When
the postfix package was installed with the "No configuration" mailer type and
ships no `/etc/postfix/main.cf` or `master.cf`, the installer restores both from
the package templates (`/usr/share/postfix/main.cf.debian` and
`master.cf.dist`) before writing any setting. A `compatibility_level` below `2`
is raised to `3.6`: levels `0` and `1` select Postfix's backwards-compatible
legacy defaults, which this configuration does not intend (Postfix reports the
compiled-in default `0` when `main.cf` does not set one).

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

| Option                        | Description                                                        |
| ----------------------------- | ------------------------------------------------------------------ |
| `--mailcow-host HOST`         | Mailcow API hostname                                               |
| `--primary-ip IP`             | Primary Mailcow IP used for delivery                               |
| `--api-key KEY`               | API key inline (visible in `ps`; prefer stdin)                     |
| `--api-key-stdin`             | Read the API key from standard input                               |
| `--ca-file PATH`              | Private CA bundle for the Mailcow API certificate                  |
| `--smtp-tls-mode may\|secure` | Outbound TLS policy (default `may`)                                |
| `--tls-match HOSTNAME`        | Certificate name for `secure` mode                                 |
| `--release VERSION`           | Install a specific release instead of the latest                   |
| `--local-dir DIR`             | Install from a local checkout/release (offline, no release needed) |
| `--sha256 HEX`                | Verify the installer file before running                           |
| `--config FILE`               | Read values from a shell-style file                                |
| `--non-interactive`           | Never prompt                                                       |
| `--yes`                       | Skip the confirmation question                                     |
| `--skip-upgrade`              | Do not upgrade existing Ubuntu packages                            |
| `--skip-initial-sync`         | Do not run the first synchronization                               |
| `--no-firewall`               | Do not configure UFW                                               |
| `--force`                     | Proceed on otherwise fatal warnings                                |

Re-running the installer is safe; what it preserves and how it behaves when the
first synchronization fails is in [`README.md`](README.md#installation).

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
sudo mx-diagnose                 # /var/log/mailcow-backup-mx/diagnostics/health-*.md
sudo mx-diagnose --stdout        # print to stdout
sudo mx-diagnose --out /root --lines 400
```

The report opens with an analysis prompt, then these sections:

| Section                            | What to look at first                                                   |
| ---------------------------------- | ----------------------------------------------------------------------- |
| 1. System                          | disk and memory pressure, failed units                                  |
| 2. Postfix                         | version, `relay_domains`/`relay_recipients`, queue and deferral reasons |
| 3. Mailcow synchronization         | last attempt/success, counts, cache age, relaxed flag                   |
| 4. Connectivity                    | API, SMTP and TLS results, certificate expiry                           |
| 5. Security posture                | file modes, exposed ports, firewall                                     |
| 6. Application version and updates | installed version, last package update, pending reboot                  |
| 7. Recent system errors            | journal and install log excerpts                                        |

It also covers system resources, listening sockets, effective Postfix
configuration, map and timer history, and recent sanitized logs. How to read it
as an operator is in
[`README.md`](README.md#check-the-health-of-the-server).

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
