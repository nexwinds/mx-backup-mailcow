# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `mailcow/allowlist-backup-mx.sh` runs on the **Mailcow host** and makes the two
  changes Mailcow needs to trust the backup MX: it permits the address in
  `data/conf/postfix/custom_postscreen_whitelist.cidr` and disables rspamd
  greylisting for it in `data/conf/rspamd/local.d/settings.conf`, without
  touching tracked Mailcow files. It discovers the postscreen file from
  `postconf -h postscreen_access_list`, translates container paths through
  bind mounts, edits marker-delimited blocks, validates with `postmap -q`,
  `rspamadm configtest` and `rspamadm configdump`, and rolls back on failure.
  `--check` reports drift after a Mailcow update, `--remove` undoes it, and the
  address list is kept in `/etc/mailcow-backup-mx-allowlist.conf`. The script is
  shipped in the release at `share/mailcow/` and installed under
  `/opt/mx-backup-mailcow/share/mailcow/`.
- `install.sh` refuses a hostname that is not fully qualified instead of warning
  and continuing. `myhostname`, `myorigin` and the HELO/DSN domain are taken from
  it, so a single label (`mxbk`) produced a HELO that strict receivers reject and
  DSN senders that fail SPF/DMARC. `--hostname FQDN` and the `BACKUP_MX_HOSTNAME`
  key override the detected name.
- Inbound TLS: `--inbound-tls-cert`/`--inbound-tls-key` (or a certbot tree at
  `/etc/letsencrypt/live/<hostname>/`) stage the chain and key in
  `/etc/postfix/tls` with `root:postfix` ownership, because Postfix reads the key
  as the unprivileged `postfix` user. A certbot deploy hook refreshes the copy
  on renewal. `--no-inbound-tls` keeps STARTTLS off and the installer states what
  that costs.
- `OPERATIONAL_MAIL_TO` forwards root/postmaster/abuse/... mail to an operator
  instead of discarding it silently.
- Install-time verification: the clock must be synchronized, the primary's SMTP
  certificate must verify for `SMTP_TLS_MATCH_HOSTNAME` in `secure` mode, and
  after the first synchronization a local `RCPT` dialogue must accept a
  synchronized recipient and reject an unknown one.
- `mx-diagnose` reports inbound STARTTLS, chroot/map visibility, the local RCPT
  probe, forward-hop TLS verification, delivery evidence, map consistency and
  the clock state; the HTTPS probe now tries every resolved address and prints
  the current time.
- `mx-diagnose` prints a short terminal summary after writing the report:
  Postfix/timer state, queue length, last synchronization, domain and mailbox
  counts, inbound and outbound TLS, queue disk, and a plain
  `healthy`/`needs attention` verdict. The report path stays the last stdout
  line; with `--stdout` the summary goes to stderr so the report remains
  pipeable.
- `OPERATIONS.md` and `TROUBLESHOOTING.md`: the README now keeps the overview,
  requirements, Quick start, Quick update, API key, Mailcow allowlist and health
  verdict table; installation detail, architecture, DNS, configuration,
  maintenance and security moved to `OPERATIONS.md`, and the symptom table and
  diagnostics moved to `TROUBLESHOOTING.md`. Both files, plus `DOCS.md`, are now
  staged in releases under `share/doc/`.

### Changed

- `SMTP_TLS_MODE` defaults to `secure` with `SMTP_TLS_MATCH_HOSTNAME` defaulting
  to `MAILCOW_HOST`. The previous default (`may`) accepted any certificate, or
  none, on the only hop that carries queued mail. `may` remains available and is
  logged as unauthenticated.
- The `aliases` map is indexed with `postalias` instead of `postmap`, which
  warned `record is in "key: value" format; is this an alias file?` for every
  line.
- `smtpd`/`smtp` run with `chroot=n` when the generated maps are not present
  inside `$queue_directory`; a chrooted process cannot read `/etc/postfix`. The
  change is logged, and is skipped when the maps are in the jail.
- The unused `uucp`, `lmtp` and `virtual` services are removed from `master.cf`;
  `smtpd_forbid_unauth_pipelining=yes` is set.
- `sync-mailcow.sh` verifies all four map references (including `transport_maps`
  and `smtp_tls_policy_maps`) and refuses a generated map in which a relay domain
  has no transport entry, which would loop mail back to this host.
- Removed `MANUAL-SETUP.md`. The by-hand deployment path was untested, duplicated
  the Postfix settings in `install.sh` and had begun to drift; the installer is
  now the only supported deployment. The map-file formats and the lab
  verification checks moved to [`DOCS.md`](DOCS.md), and the Postfix reference
  points at the `settings` array in `install.sh` instead of repeating it.
- CI and the release workflow use `actions/checkout@v5`, run under an 8-minute
  job ceiling, and install `shellcheck`/`jq` only when the runner image lacks
  them. The diagnostic test mock now reports `/dev/tcp` probes as timeouts
  instead of opening a socket, cutting the suite from about 12 minutes to well
  under the cap.

### Fixed

- `scripts/build-release.sh` writes `dist/SHA256SUMS` with a single two-space
  separator. The previous pattern left a leading space in the filename, which
  made `sha256sum -c SHA256SUMS` fail in CI and for anyone verifying a
  downloaded asset. `tests/test-release.sh` now runs `sha256sum -c` itself, so
  the manifest is validated the way a user validates it.
- `install.sh` now restores `/etc/postfix/main.cf` and `/etc/postfix/master.cf`
  from the package templates when the postfix package was installed with the
  "No configuration" mailer type and shipped neither file. Previously the first
  `postconf -e` failed, which aborted the run before the firewall, the API check
  and the initial synchronization.
- `install.sh` never writes a `compatibility_level` below `2` (the compiled-in
  default is `0` when `main.cf` is absent; `0` and `1` select Postfix's legacy
  compatibility defaults) and stops with a clear error if Postfix does not
  start after configuration.
- `diagnose.sh` writes the configuration summary, file permissions and installed
  version sections to the report instead of standard output, so `mx-diagnose`
  prints only the report path.
- `diagnose.sh` no longer masks the unit name `postfix@-.service` as an email
  address; an instance that starts with an alphanumeric character is still
  masked (`getty@tty1.service` becomes `g***@tty1.service`).
- `diagnose.sh` reports why the HTTPS certificate could not be read instead of
  emitting an unexplained `Could not read certificate from <stdin>`.

## [1.0.0] - 2026-11-14

### Added

- Initial release.
- `install.sh` for Ubuntu 24.04 LTS provisioning with release bootstrap.
- `sync-mailcow.sh` with read-only Mailcow API synchronization every two hours,
  atomic map updates, validation, cache fallback, rollback and relaxation after
  seven days without a successful synchronization.
- `update.sh` for independent Ubuntu package updates.
- `diagnose.sh` for read-only, AI-ready health reports.
- `update-scripts.sh` for verified GitHub Release updates with rollback.
- Postfix backup MX configuration, systemd units, log rotation and tests.
