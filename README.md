# mx-backup-mailcow

A lightweight, production-ready **Backup MX for Mailcow**, built on **Ubuntu
Server 24.04 LTS** and **standalone Postfix**.

When the primary Mailcow server is unavailable, the backup MX accepts mail for
the synchronized domains, queues it locally and forwards it to the primary IP
when it recovers. No Docker, no database, no extra mail server components.

- **Version:** see [`VERSION`](VERSION)
- **License:** MIT — see [`LICENSE`](LICENSE)
- **Repository:** <https://github.com/nexwinds/mx-backup-mailcow>
- **Website:** <https://nexwinds.com>
- **Affiliation:** Independent project — not affiliated with the Mailcow project
- **Status:** pre-release. No GitHub Release is published yet; the first one is
  created once the application is declared stable. Until then, install from a
  checkout with `--local-dir` as shown in [Quick start](#quick-start), and
  update by pulling the repository again.

## Documentation

| Document                                   | Audience                                        | Contents                                                                                           |
| ------------------------------------------ | ----------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| **README.md** (this file)                  | technician deploying or operating a server      | requirements, installation, API key, health checks, configuration, maintenance, troubleshooting    |
| [`MANUAL-SETUP.md`](MANUAL-SETUP.md)       | whoever cannot or will not run `install.sh`     | by-hand deployment: packages, config file, Postfix maps, systemd units, log rotation, verification |
| [`DOCS.md`](DOCS.md)                       | anyone looking up a fact                        | runtime layout, configuration keys and overrides, script flags, map and state tables               |
| [`CONTRIBUTING.md`](CONTRIBUTING.md)       | anyone sending a bug report, a fix or a feature | project scope, development setup, tests, code rules, commit and pull request conventions           |
| [`MAINTAINER.md`](MAINTAINER.md)           | whoever publishes the project                   | repository layout, CI internals, building and publishing a release, deferred simplifications       |
| [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) | everyone                                        | Contributor Covenant 2.1                                                                           |

## Contents

**Deploy and operate:** [Requirements](#requirements) ·
[Quick start](#quick-start) · [Get the Mailcow API key](#get-the-mailcow-api-key) ·
[Allow the backup MX in Mailcow](#allow-the-backup-mx-in-mailcow) ·
[Installation](#installation) · [Check the health](#check-the-health-of-the-server)

**Reference:** [Features](#features) · [Architecture](#architecture) ·
[DNS and firewall](#dns-and-firewall) ·
[Releases and updates](#releases-and-application-updates) ·
[Maintenance](#maintenance) · [Troubleshooting](#troubleshooting) ·
[Security notes](#security-notes) · [Limitations](#limitations) ·
[DOCS.md](DOCS.md)

**Contributing:** [Contributing](#contributing) ·
[CONTRIBUTING.md](CONTRIBUTING.md) · [Code of conduct](CODE_OF_CONDUCT.md)

---

## Requirements

- A fresh **Ubuntu Server 24.04 LTS** host (physical, VM or VPS) with a public
  IPv4 address and a fully qualified hostname.
- Inbound **TCP/25** reachable from the internet; outbound **TCP/25** to the
  primary Mailcow, plus outbound **TCP/443** to Mailcow and GitHub.
- Root/sudo access.
- A Mailcow server with:
  - a **read-only API key**, restricted to the backup MX public IP
    (see [Get the Mailcow API key](#get-the-mailcow-api-key));
  - the backup MX IP allowlisted in Mailcow's Postfix/Rspamd filters if they
    are strict.

No Docker, database server, PMG, web server or extra daemon is required.

## Quick start

Five commands on a freshly installed VPS. Everything else is prompts and
verification.

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/nexwinds/mx-backup-mailcow.git
cd mx-backup-mailcow
sudo bash install.sh --local-dir .
sudo mx-diagnose
```

| Command | What it does                                                                                   |
| ------- | ---------------------------------------------------------------------------------------------- |
| 1       | installs `git`, the only prerequisite                                                          |
| 2       | downloads the project                                                                          |
| 3       | enters the project directory                                                                   |
| 4       | runs the installer against this checkout (`--local-dir .`), which avoids downloading a release |
| 5       | prints a health report you can read top-down                                                   |

Before running command 4 you need a read-only API key from the Mailcow
interface: one browser step, described in the next section.

The installer asks only these questions:

```text
Mailcow hostname (API endpoint): mail.example.com
Primary Mailcow IP address: 203.0.113.10
Read-only API key:                 (input hidden)
Private CA file for the API (optional):
SMTP TLS mode for the primary (may/secure): may
```

It also prints a summary and the next DNS step when it finishes.

Once the first GitHub Release is published, the two-command alternative
becomes available:

```bash
curl -fsSL -o install.sh \
  https://github.com/nexwinds/mx-backup-mailcow/releases/latest/download/install.sh
sudo bash install.sh
```

## Get the Mailcow API key

Do this **before** the installer asks for the key. The key is read-only and
does nothing outside the Mailcow API, so it is safe to create first.

1. Open your Mailcow web interface, for example
   `https://mail.example.com`, and log in **as an administrator**.
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
8. If you skipped the installer prompt, confirm the key works from the backup
   MX with the project's own pattern (key on stdin, never in the command
   line):

   ```bash
   printf 'url = "https://mail.example.com/api/v1/get/domain/all"\nheader = "X-API-Key: PASTE-KEY-HERE"\n' \
     | curl -s -o /dev/null -w '%{http_code}\n' --config -
   ```

   `200` means the key, the IP allowlist and the certificate are all correct.
   `401`/`403` means the key is wrong, inactive or the IP is not allowlisted.
   `000` means DNS, firewall or TLS.

The installer replaces the key in the same place later if you re-run it, so an
expired or rotated key is a matter of re-running `install.sh` and pasting the
new one.

## Allow the backup MX in Mailcow

If Mailcow's filters are strict, the backup MX IP must be allowed through them
before mail can be relayed and synchronized.

1. Allow the backup MX IP through Mailcow's filters:

   ```bash
   # /opt/mailcow-dockerized/data/conf/postfix/custom_postscreen_whitelist.cidr
   203.0.113.20/32
   ```

   Reload Mailcow's Postfix afterwards:

   ```bash
   cd /opt/mailcow-dockerized
   docker compose exec postfix-mailcow postfix reload
   ```

   If Rspamd greylisting is configured aggressively, add the IP to the Rspamd
   whitelist as well.

2. Do **not** enable Mailcow's own "relay this domain" feature for domains that
   the backup MX serves; the backup MX synchronizes recipients directly.

## Installation

### Interactive installation

Already covered by [Quick start](#quick-start). The installer asserts root,
verifies Ubuntu 24.04 LTS, and then:

1. obtains the application tree — a verified release, or the checkout itself
   with `--local-dir`;
2. updates Ubuntu packages and installs `postfix`, `jq`, `curl`, `ufw` and
   `logrotate`;
3. writes `/etc/mailcow-backup-mx/config` with mode `0600`;
4. configures Postfix as a backup MX;
5. installs the scripts, systemd units and log rotation;
6. configures UFW (SSH port detected automatically, plus TCP/25);
7. verifies API connectivity and performs the initial synchronization.

Without `--local-dir`, running the installer from a checkout still downloads and
verifies the GitHub Release it installs. With it, the checkout itself is what
gets installed and GitHub is never contacted.

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

## Check the health of the server

### Start with the verdict

Four commands, about a minute, answering "is it working right now?".

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

### Then read the full report

```bash
sudo mx-diagnose
```

It prints the report path and writes a file under
`/var/log/mailcow-backup-mx/diagnostics/`; `--stdout`, `--out` and `--lines`
are described in [`DOCS.md`](DOCS.md#diagnosesh).

The report starts with a prompt for an experienced Linux/Postfix administrator
and then walks through system, Postfix, synchronization, connectivity, security,
update and error state. The section list, what is collected, and the redaction
rules are in [`DOCS.md`](DOCS.md#diagnosesh).

The report is read-only: nothing is changed, restarted or flushed, and the file
(mode `0600`) is safe to hand to a colleague or an AI assistant.

## Features

- **Postfix-only backup MX.** Receives SMTP on port 25, validates recipients,
  queues mail and relays it directly to the primary Mailcow IP.
- **Automatic domain/recipient synchronization** from the Mailcow REST API
  every two hours, using a read-only API key restricted to this server's IP.
- **Safe updates.** Maps are generated in a staging directory, validated,
  compared and installed atomically. A failed synchronization never destroys
  the maps that are in use.
- **Offline cache.** When Mailcow or its API is unavailable, maps are rebuilt
  from cached data so the backup MX keeps working.
- **Automatic recovery.** Postfix retries delivery with a short backoff until
  the primary is reachable again.
- **Bounded acceptance.** Only active Mailcow domains are relayed, only known
  recipients are accepted, and `@domain` wildcards cover catch-all aliases,
  alias domains and `relay_all_recipients` domains.
- **Prolonged-outage mode.** After seven days without a successful API sync,
  hosted domains temporarily accept all recipients to avoid rejecting newly
  created addresses. Strict validation returns automatically on the next
  successful sync.
- **No mailbox hosting.** Local operational mail is discarded; no IMAP, POP3,
  webmail or local mailboxes.
- **Verified updates.** Application updates come from signed-off GitHub
  Releases, are checked against SHA-256 manifests, validated with `bash -n` and
  ShellCheck, and can be rolled back.
- **AI-ready diagnostics.** A read-only diagnostic command produces a
  structured report with an analysis prompt, redacting credentials, keys and
  message content.

## Architecture

```
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

1. The sender's MTA tries the primary MX (priority 10). If it is unreachable,
   it falls back to the backup MX (priority 20).
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
- If the backup MX sends delay warnings or bounces directly, SPF does not apply
  to the null envelope sender, but the hostname should still resolve and have a
  PTR record.
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

Settings live in `/etc/mailcow-backup-mx/config` (owner `root`, mode `0600`).
The installer writes it; edit it only for values the installer does not ask
for. Every key, its default, the `MXB_*` path overrides and the Postfix
settings the installer applies are in [`DOCS.md`](DOCS.md#configuration).

To apply the same Postfix configuration by hand, including the aliases file and
the seed maps, use [`MANUAL-SETUP.md`](MANUAL-SETUP.md#step-5--postfix).

## Scripts

Four commands: `sync-mailcow.sh` (also run by the timer), `mx-update`,
`mx-diagnose` and `mx-update-scripts`. Their flags, what each one protects, and
the state files they write are in [`DOCS.md`](DOCS.md#scripts-and-flags).

What the two-hour synchronization writes into the maps, which Mailcow objects
become recipient entries, and how failures are handled are in
[`DOCS.md`](DOCS.md#synchronization-and-maps).

## Releases and application updates

- Versions follow **Semantic Versioning** (`MAJOR.MINOR.PATCH`) and are stored
  in `VERSION`.
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
Ubuntu packages; both are documented in
[`DOCS.md`](DOCS.md#scripts-and-flags). Building and publishing releases is a
maintainer task, described in [`MAINTAINER.md`](MAINTAINER.md#publishing-a-release).

## Maintenance

Routine checks are in
[Check the health of the server](#check-the-health-of-the-server); the
synchronization, update and diagnostic flags are in
[`DOCS.md`](DOCS.md#scripts-and-flags).

```bash
sudo systemctl list-timers mailcow-sync.timer   # when the next run is due
sudo postqueue -p                               # inspect the queue
sudo postqueue -j | jq .                        # queue as JSON
sudo postqueue -f                               # force a retry of the queue
```

Capacity: the queue lives under `/var/spool/postfix`. Monitor free space with
`mx-diagnose`; the report includes disk and inode usage and queue size.

## Troubleshooting

| Symptom                                    | Check                                                                         | Action                                                                        |
| ------------------------------------------ | ----------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `API authentication failed (HTTP 401/403)` | Mailcow API key, read-only flag, IP allowlist                                 | Recreate the key with the correct IP; run `sync-mailcow.sh`                   |
| `TLS verification failed`                  | Certificate chain of the Mailcow API                                          | Supply the private CA with `--ca-file`; do not disable verification           |
| `Postfix does not reference ...`           | `postconf -h relay_recipient_maps`                                            | Re-run `install.sh`                                                           |
| Unknown recipient is accepted              | `postmap -q user@domain hash:/etc/postfix/mailcow-backup-mx/relay_recipients` | Check Mailcow active state; `sync-mailcow.sh --dry-run`                       |
| Known recipient is rejected                | Map contents, `EXCLUDE_DOMAINS`, source domain active                         | Run a sync with `--force` after verifying the API output                      |
| Queue grows while the primary is down      | `postqueue -p`, `postfix status`                                              | Verify the primary IP/port and outbound TCP/25; Postfix retries automatically |
| Mail expires                               | `maximal_queue_lifetime` and outage duration                                  | Increase `QUEUE_LIFETIME` in the config only if justified                     |
| Timer does not run                         | `systemctl list-timers`, `systemctl status`                                   | `systemctl enable --now mailcow-sync.timer`                                   |
| Maps not applied                           | `sync-mailcow.sh` log, `postfix status`                                       | The script reloads Postfix only when a map or its index changed               |
| Installer cannot download a release        | Repository/release exists, outbound HTTPS                                     | Use `--local-dir` or `--release`                                              |
| `update-scripts` rate limited              | GitHub API quota                                                              | Retry later or use `--release VERSION`                                        |

Diagnostics:

```bash
sudo mx-diagnose --stdout
sudo journalctl -u mailcow-sync.service -n 100 --no-pager
sudo tail -n 100 /var/log/mailcow-backup-mx/sync.log
```

To prove that recipient validation and queue recovery actually work, use the
lab checks in [`MANUAL-SETUP.md`](MANUAL-SETUP.md#verification).

## Security notes

- The API key is read-only, restricted to the backup MX IP in Mailcow, stored in
  a `0600` root-owned file, passed to curl via stdin, and redacted from logs.
- HTTPS is mandatory for the API, with TLS 1.2+ and certificate verification.
  There is no insecure mode; use `--ca-file` for private CAs.
- The server is not an open relay: `mynetworks` is limited to loopback, unknown
  domains are rejected by `reject_unauth_destination`, and unknown recipients
  are rejected by `relay_recipient_maps`.
- Only port 25 is exposed. No submission, IMAP, POP3, webmail or local mailbox
  storage is provided.
- Application updates are checksum-verified, syntax-checked and rollback-able.
- Diagnostics never mutate the server and redact credentials and message
  content.

## Limitations

- No spam filtering or antivirus on the backup MX; it queues and forwards.
- No DKIM signing. Original signatures are preserved, but the backup MX does
  not add one.
- If the primary rejects a recipient after synchronization (for example a
  mailbox deleted during an outage), the primary's 5xx response produces a
  bounce to the sender. Keep the map fresh.
- Relaxed mode accepts all recipients for hosted domains during a prolonged
  outage; invalid addresses are rejected by the primary later.
- The GitHub updater relies on the public Releases API and its unauthenticated
  rate limit.
- Internationalized domains must be stored in Mailcow in ACE/punycode form
  (`xn--`); Unicode domain names are not converted by the synchronization.
- UFW is the supported firewall manager. Other firewall tools are left
  untouched and must be configured manually.

## File layout

The installed paths are listed in [`DOCS.md`](DOCS.md#runtime-layout); the
source repository layout is in
[`MAINTAINER.md`](MAINTAINER.md#repository-layout).

## Contributing

Scope, development setup, tests and pull request rules are in
[`CONTRIBUTING.md`](CONTRIBUTING.md); participation is covered by
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md). Report vulnerabilities privately
through the repository's _Security → Report a vulnerability_ tab, never in a
public issue.

## Disclaimer

This is an independent project. It is **not affiliated with, endorsed by, or
sponsored by the Mailcow project or its maintainers**. "Mailcow" and related
marks are trademarks of their respective owners and are used here only to
describe interoperability.

## License

MIT License — use, modify, sublicense and redistribute, including in closed
source, provided the copyright notice and permission text in
[`LICENSE`](LICENSE) stay with the software.

Copyright (c) 2026 **Nexwinds Solutions Lda**, registered in Portugal —
<https://nexwinds.com>.
