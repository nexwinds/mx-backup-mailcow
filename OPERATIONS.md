# Operations guide

Detailed procedures for deploying and running **mx-backup-mailcow**. Start with
[`README.md`](README.md) for the overview, requirements, Quick start and Quick
update; look up individual facts in [`DOCS.md`](DOCS.md). When something is
wrong, use [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).

## Contents

- [Get the Mailcow API key](#get-the-mailcow-api-key)
- [Allow the backup MX in Mailcow](#allow-the-backup-mx-in-mailcow)
- [Installation](#installation)
- [Check the health of the server](#check-the-health-of-the-server)
- [Architecture](#architecture)
- [DNS and firewall](#dns-and-firewall)
- [Configuration](#configuration)
- [Scripts](#scripts)
- [Releases and application updates](#releases-and-application-updates)
- [Maintenance](#maintenance)
- [Security notes](#security-notes)
- [Limitations](#limitations)
- [File layout](#file-layout)

## Get the Mailcow API key

Do this **before** the installer asks for the key. The key is read-only and does
nothing outside the Mailcow API, so it is safe to create first.

1. Open your Mailcow web interface, for example `https://mail.example.com`, and
   log in **as an administrator**.
2. Go to **System → Configuration → Access**.
3. In the **Administrators** section, open the **API** entry
   (_Administrators → API_).
4. Choose **Add API key**.
5. Fill in the fields:
   - **Description:** `mx-backup-mailcow` (so you can identify it later);
   - **Access:** **Read-Only Access**;
   - **Allowed IPs:** the public IP of the backup MX server, one per line.
     Using a single IP is the point: the key is useless anywhere else;
   - **Active:** yes.
6. Save the key and **copy it immediately** — Mailcow shows the full key only
   once. Store it in a password manager.
7. Paste it at the installer prompt. The input is hidden, so the key never
   appears on screen, in scrollback, in `ps` or in a log.
8. If you skipped the installer prompt, confirm the key works from the backup MX
   with the project's own pattern (key on stdin, never in the command line):

   ```bash
   printf 'url = "https://mail.example.com/api/v1/get/domain/all"\nheader = "X-API-Key: PASTE-KEY-HERE"\n' \
     | curl -s -o /dev/null -w '%{http_code}\n' --config -
   ```

   `200` means the key, the IP allowlist and the certificate are all correct.
   `401`/`403` means the key is wrong, inactive or the IP is not allowlisted.
   `000` means DNS, firewall or TLS.

The installer replaces the key in the same place later if you re-run it, so an
expired or rotated key is a matter of re-running `install.sh` and pasting the new
one.

## Allow the backup MX in Mailcow

Mailcow sees every queued message as coming from the backup MX, so it must not
greylist that address. The project ships a script for the **Mailcow host** that
makes the two supported changes, validates them, and can undo them:

```bash
# on the backup MX: fetch the script
scp /opt/mx-backup-mailcow/share/mailcow/allowlist-backup-mx.sh root@mail.example.com:/root/

# on the Mailcow host: allow the backup MX once
sudo bash /root/allowlist-backup-mx.sh --ip 203.0.113.20
```

It edits only files that Mailcow includes but never generates:

| Change               | File                                                 | Effect                                          |
| -------------------- | ---------------------------------------------------- | ----------------------------------------------- |
| postscreen allowlist | `data/conf/postfix/custom_postscreen_whitelist.cidr` | no greet/DNSBL delay or greylisting at the edge |
| rspamd greylisting   | `data/conf/rspamd/local.d/settings.conf`             | no greylisting; spam/virus/DKIM/SPF stay active |

Both edits sit in marker-delimited blocks, so existing entries survive,
re-running is a no-op, and `--remove` restores the previous state. `--check`
exits non-zero when an update changed anything, and `--dry-run` shows the diff.

Mailcow updates do not conflict with these files, but they can revert them, so
after each update run the script again:

```bash
cd /opt/mailcow-dockerized
sudo apt update && sudo apt upgrade -y
./update.sh
sudo bash /root/allowlist-backup-mx.sh            # repairs drift
```

The script's flags, discovery rules and validation steps are in
[`DOCS.md`](DOCS.md#mailcow-side-allowlist).

Do **not** enable Mailcow's own "relay this domain" feature for domains that the
backup MX serves; the backup MX synchronizes recipients directly.

## Installation

`install.sh` is the only supported deployment path. There is no by-hand
procedure to keep in sync with it.

### Interactive installation

Already covered by [Quick start](README.md#quick-start). The installer asserts
root, verifies Ubuntu 24.04 LTS, and then:

1. obtains the application tree — a verified release, or the checkout itself
   with `--local-dir`;
2. refuses a hostname that is not a FQDN and a clock that has not synchronized,
   because both make TLS and queue timing unreliable;
3. updates Ubuntu packages and installs `postfix`, `jq`, `curl`, `ufw` and
   `logrotate`;
4. writes `/etc/mailcow-backup-mx/config` with mode `0600`;
5. configures Postfix as a backup MX, stages inbound TLS where the `postfix` user
   can read it, and disables chroot for services that must read the maps;
6. installs the scripts, systemd units and log rotation;
7. configures UFW (SSH port detected automatically, plus TCP/25);
8. verifies API connectivity, then verifies the primary's SMTP certificate;
9. performs the initial synchronization and self-tests the local SMTP path
   (`RCPT` for a synchronized recipient must be accepted, an unknown one
   rejected).

Without `--local-dir`, running the installer from a checkout still downloads and
verifies the GitHub Release it installs. With it, the checkout itself is what gets
installed and GitHub is never contacted.

### Non-interactive installation

```bash
sudo bash install.sh --non-interactive --local-dir . \
  --mailcow-host mail.example.com \
  --primary-ip 203.0.113.10 \
  --api-key-stdin \
  --yes
```

Paste the API key when prompted (stdin), or supply it with a root-only file:

```bash
sudo bash install.sh --non-interactive --local-dir . \
  --config /root/mx-backup.env --yes
```

```bash
# /root/mx-backup.env (mode 0600)
MAILCOW_HOST="mail.example.com"
MAILCOW_API_KEY="your-read-only-key"
MAILCOW_PRIMARY_IP="203.0.113.10"
```

### Installer options

Every flag and its exact behaviour is in
[`DOCS.md`](DOCS.md#installsh); the examples above use the ones needed for an
unattended install.

The installer is **idempotent**: re-running it preserves the API key and any
unmanaged lines in the configuration file, and never deletes maps, queues or
logs. If the initial synchronization fails, the installer exits non-zero but
leaves the server configured and the timer enabled; the next run retries
automatically.

### Verify the installation

```bash
systemctl status mailcow-sync.timer
systemctl list-timers mailcow-sync.timer
sudo sync-mailcow.sh --dry-run
sudo mx-diagnose
```

`mx-diagnose` prints a short health summary and writes the full report; see
[Check the health of the server](#check-the-health-of-the-server).

## Check the health of the server

### Start with the verdict

Four commands, about a minute, answering "is it working right now?" from raw
evidence:

```bash
systemctl is-active postfix mailcow-sync.timer
sudo postqueue -p | tail -n 1
sudo jq -r '"status: \(.status) (source: \(.source))",
  "last API success: \(.last_api_success_at // \"never\")",
  "domains: \(.counts.domains)  mailboxes: \(.counts.mailboxes)  relaxed: \(.relaxed)"' \
  /var/lib/mailcow-backup-mx/state/sync-state.json
df -h /var/spool/postfix
```

| Result                                            | Meaning                                                                           |
| ------------------------------------------------- | --------------------------------------------------------------------------------- |
| both services print `active`                      | Postfix runs and the two-hour timer is enabled                                    |
| queue ends with `-- 0 Kbytes in 0 Requests.`      | nothing is waiting for the primary                                                |
| queue grows and the primary is down               | normal: mail is queued and retried every 5–15 minutes                             |
| `status: ok`                                      | last synchronization read the API and installed the maps                          |
| `status: degraded`                                | the API failed and the maps were rebuilt from cache; mail still flows             |
| `status: error`                                   | the last run failed and left the maps untouched; read `message` in the state file |
| `last API success` older than ~4 hours            | the API or the key is failing; the server is running on cache                     |
| `relaxed: true`                                   | seven days without a sync; recipients are no longer strictly validated            |
| domains/mailboxes `0` or `null`, or no state file | the first sync never succeeded; check the API key                                 |
| disk below ~10% free                              | the queue or logs need attention                                                  |

If all of that looks right, the backup MX is doing its job.

### Read the terminal summary

`sudo mx-diagnose` writes the report and then prints a summary for people who do
not want to read a diagnostic file:

```text
Health summary (version 1.0.0)

  Host:                 mx2.example.com
  Postfix:              active
  Queue:                0 messages
  Sync timer:           active
  Last sync:            ok via api, 4m ago
  Domains / mailboxes:  9 / 18
  Inbound STARTTLS:     enabled
  Outbound SMTP TLS:    secure (verified as mail.example.com)
  Queue disk:           22% used, 30G free
  Assessment:           healthy - no obvious problems detected
```

When something needs action, the last lines become:

```text
  Assessment:           needs attention
  Attention:
    - the last successful Mailcow sync is over 4 hours old
    - inbound STARTTLS is disabled; senders enforcing MTA-STS or DANE cannot deliver
```

The report path is the final line, so it can still be captured by a script or
copied into `scp`.

### Read the full report

```bash
sudo mx-diagnose              # summary, then the report path
sudo mx-diagnose --stdout     # full report on stdout; summary on stderr
sudo mx-diagnose --out /root  # write the report somewhere else
```

The report is written under `/var/log/mailcow-backup-mx/diagnostics/` with mode
`0600`; `--stdout`, `--out` and `--lines` are described in
[`DOCS.md`](DOCS.md#diagnosesh).

It starts with a prompt for an experienced Linux/Postfix administrator and then
walks through system, Postfix, synchronization, connectivity, security, update
and error state. The section list, what is collected, and the redaction rules are
in [`DOCS.md`](DOCS.md#diagnosesh).

The report is read-only: nothing is changed, restarted or flushed, and the file
is safe to hand to a colleague or an AI assistant.

## Architecture

```text
                    ┌────────────────────────────────────────────┐
   inbound SMTP     │  Ubuntu 24.04 + Postfix (backup MX)        │
   port 25          │                                            │
  ─────────────────▶│  relay_domains      (synced hash map)      │
                    │  relay_recipients   (synced hash map)      │
                    │  transport          (→ primary IP)         │
                    │  smtp_tls_policy                           │
                    │                                            │
                    │  local queue (7d, retry 5–15 min)          │
                    └───────────────┬────────────────────────────┘
                                    │ smtp:[PRIMARY_IP]:25
                                    ▼
                    ┌────────────────────────────────────────────┐
                    │  Mailcow (primary MX)                      │
                    └────────────────────────────────────────────┘

   Mailcow REST API (HTTPS, read-only, IP-allowlisted)
        │
        ▼
   sync-mailcow.sh ── every 2 hours via systemd timer
        │
        ├─ cache:  /var/lib/mailcow-backup-mx/cache/
        ├─ state:  /var/lib/mailcow-backup-mx/state/sync-state.json
        └─ maps:   /etc/postfix/mailcow-backup-mx/ (text + .db)
```

Mail flow:

1. The sender's MTA tries the primary MX (priority 10). If it is unreachable, it
   falls back to the backup MX (priority 20).
2. Postfix checks the recipient domain against `relay_domains` and the address
   against `relay_recipients`. Unknown domains and recipients are rejected.
3. Accepted messages are queued and delivered to the primary IP using the
   `transport` map.
4. While the primary is down, Postfix retries with a 5-minute minimum and a
   15-minute maximum backoff. When the primary returns, the queue is delivered
   without any manual action.

Key design choices:

| Component                | Choice                                                                       |
| ------------------------ | ---------------------------------------------------------------------------- |
| Domain/recipient storage | Postfix `hash:` maps (no SQL, no Redis)                                      |
| Recipient validation     | `relay_recipient_maps` with exact addresses and `@domain` wildcards          |
| Plus-addressing          | Works natively: Postfix strips `+tag` before the wildcard lookup             |
| Delivery target          | `transport_maps`: `domain → smtp:[PRIMARY_IP]:25` (forces the IP, never MX)  |
| Reload policy            | Postfix is reloaded only when a map or its `.db` index changed               |
| API credentials          | Read-only key, HTTPS only, stored in a root-only file, never in `ps` or logs |

## DNS and firewall

Add a lower-priority MX record for every hosted domain:

```dns
example.com.    300 IN MX 10 mail.example.com.
example.com.    300 IN MX 20 mx2.example.com.
```

- The backup MX must have an `A`/`AAAA` record and a matching `PTR` record.
- The primary IP is used for delivery regardless of DNS, so a changed MX record
  does not affect forwarding.
- If the backup MX sends delay warnings or bounces directly, SPF does not apply to
  the null envelope sender, but the hostname should still resolve and have a PTR
  record.
- No SPF change is needed for ordinary relayed mail, because the original
  sender's envelope is preserved.

Firewall (configured by the installer):

```text
inbound:  TCP/22 (or your SSH port), TCP/25
outbound: TCP/25 to the primary, TCP/443 to Mailcow and GitHub, DNS
```

The installer enables UFW with default-deny incoming. It detects the SSH port
from `/etc/ssh/sshd_config` and `sshd_config.d/*.conf`; if no port can be
determined it refuses to enable UFW rather than risk locking you out.

## Configuration

Settings live in `/etc/mailcow-backup-mx/config` (owner `root`, mode `0600`). The
installer writes it; edit it only for values the installer does not ask for.
Every key, its default, the `MXB_*` path overrides and the Postfix settings the
installer applies are in [`DOCS.md`](DOCS.md#configuration); the authoritative
Postfix list is the `settings` array in [`install.sh`](install.sh).

## Scripts

Four commands: `sync-mailcow.sh` (also run by the timer), `mx-update`,
`mx-diagnose` and `mx-update-scripts`. Their flags, what each one protects, and
the state files they write are in [`DOCS.md`](DOCS.md#scripts-and-flags).

What the two-hour synchronization writes into the maps, which Mailcow objects
become recipient entries, and how failures are handled are in
[`DOCS.md`](DOCS.md#synchronization-and-maps).

## Releases and application updates

- Versions follow **Semantic Versioning** (`MAJOR.MINOR.PATCH`) and are stored in
  `VERSION`.
- Only published GitHub Releases are used; branch and tarball downloads are not
  supported by the updater. The release asset contract is in
  [`MAINTAINER.md`](MAINTAINER.md#building-a-release-locally).

**Current status:** the project is pre-release, so `mx-update-scripts` has
nothing to fetch yet. Until the first release is published, update a server by
pulling the repository and re-running the installer:

```bash
cd mx-backup-mailcow
git pull
sudo bash install.sh --local-dir .
```

Afterwards `mx-update-scripts` handles the application and `mx-update` handles
Ubuntu packages; both are documented in [`DOCS.md`](DOCS.md#scripts-and-flags).
Building and publishing releases is a maintainer task, described in
[`MAINTAINER.md`](MAINTAINER.md#publishing-a-release).

## Maintenance

Routine checks are in [Check the health of the server](#check-the-health-of-the-server);
the synchronization, update and diagnostic flags are in
[`DOCS.md`](DOCS.md#scripts-and-flags).

```bash
sudo systemctl list-timers mailcow-sync.timer   # when the next run is due
sudo postqueue -p                               # inspect the queue
sudo postqueue -j | jq .                        # queue as JSON
sudo postqueue -f                               # force a retry of the queue
```

Capacity: the queue lives under `/var/spool/postfix`. Monitor free space with
`mx-diagnose`; the report includes disk and inode usage and queue size.

## Security notes

- The API key is read-only, restricted to the backup MX IP in Mailcow, stored in
  a `0600` root-owned file, passed to curl via stdin, and redacted from logs.
- HTTPS is mandatory for the API, with TLS 1.2+ and certificate verification.
  There is no insecure mode; use `--ca-file` for private CAs.
- The server is not an open relay: `mynetworks` is limited to loopback, unknown
  domains are rejected by `reject_unauth_destination`, and unknown recipients are
  rejected by `relay_recipient_maps`.
- Outbound SMTP TLS to the primary is verified by default (`secure match=<name>`);
  `--smtp-tls-mode may` is an explicit, logged downgrade.
- Inbound TLS uses a certificate the `postfix` user can read; the copy in
  `/etc/postfix/tls` is refreshed by a certbot deploy hook on renewal.
- Only port 25 is exposed. No submission, IMAP, POP3, webmail or local mailbox
  storage is provided.
- Application updates are checksum-verified, syntax-checked and rollback-able.
- Diagnostics never mutate the server and redact credentials and message content.

## Limitations

- No spam filtering or antivirus on the backup MX; it queues and forwards.
- No DKIM signing. Original signatures are preserved, but the backup MX does not
  add one.
- If the primary rejects a recipient after synchronization (for example a mailbox
  deleted during an outage), the primary's 5xx response produces a bounce to the
  sender. Keep the map fresh.
- Relaxed mode accepts all recipients for hosted domains during a prolonged
  outage; invalid addresses are rejected by the primary later.
- The GitHub updater relies on the public Releases API and its unauthenticated
  rate limit.
- Internationalized domains must be stored in Mailcow in ACE/punycode form
  (`xn--`); Unicode domain names are not converted by the synchronization.
- UFW is the supported firewall manager. Other firewall tools are left untouched
  and must be configured manually.

## File layout

The installed paths are listed in [`DOCS.md`](DOCS.md#runtime-layout); the source
repository layout is in [`MAINTAINER.md`](MAINTAINER.md#repository-layout).
