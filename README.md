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
  update as shown in [Quick update](#quick-update).

## Documentation

| Document                                   | Audience                                        | Contents                                                                                    |
| ------------------------------------------ | ----------------------------------------------- | ------------------------------------------------------------------------------------------- |
| **README.md** (this file)                  | technician deploying or operating a server      | requirements, Quick start, Quick update, API key, Mailcow allowlist, health summary         |
| [`OPERATIONS.md`](OPERATIONS.md)           | anyone performing a procedure                   | installation details, health report, architecture, DNS/firewall, configuration, maintenance |
| [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) | anyone fixing a problem                         | symptom table, summary verdicts, diagnostics, report sections                               |
| [`DOCS.md`](DOCS.md)                       | anyone looking up a fact                        | runtime layout, configuration keys and overrides, script flags, map and state tables        |
| [`CONTRIBUTING.md`](CONTRIBUTING.md)       | anyone sending a bug report, a fix or a feature | project scope, development setup, tests, code rules, commit and pull request conventions    |
| [`MAINTAINER.md`](MAINTAINER.md)           | whoever publishes the project                   | repository layout, CI internals, building and publishing a release                          |
| [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) | everyone                                        | Contributor Covenant 2.1                                                                    |

## Contents

**Deploy and operate:** [Requirements](#requirements) · [Quick start](#quick-start) ·
[Quick update](#quick-update) · [Get the Mailcow API key](#get-the-mailcow-api-key) ·
[Allow the backup MX in Mailcow](#allow-the-backup-mx-in-mailcow) ·
[Check the health](#check-the-health-in-one-minute)

**Reference:** [What it does](#what-it-does) · [`OPERATIONS.md`](OPERATIONS.md) ·
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) · [`DOCS.md`](DOCS.md)

**Contributing:** [Contributing](#contributing) · [`CONTRIBUTING.md`](CONTRIBUTING.md) ·
[Code of conduct](CODE_OF_CONDUCT.md)

---

## Requirements

- A fresh **Ubuntu Server 24.04 LTS** host (physical, VM or VPS) with a public
  IPv4 address and a fully qualified hostname whose A/AAAA **and PTR** records
  point at this server. The installer refuses a single-label hostname: Postfix
  uses it as the HELO name and as the DSN sender domain, and it cannot hold a
  certificate.
- Inbound **TCP/25** reachable from the internet; outbound **TCP/25** to the
  primary Mailcow, plus outbound **TCP/443** to Mailcow and GitHub.
- For inbound TLS, a certificate for the hostname (certbot is detected
  automatically). Without one, port 25 runs without STARTTLS and senders that
  enforce MTA-STS or DANE cannot deliver to it.
- Root/sudo access.
- A Mailcow server with:
  - a **read-only API key**, restricted to the backup MX public IP
    (see [Get the Mailcow API key](#get-the-mailcow-api-key));
  - the backup MX IP trusted by Mailcow's postscreen and rspamd, one command
    with [`mailcow/allowlist-backup-mx.sh`](#allow-the-backup-mx-in-mailcow).

No Docker, database server, PMG, web server or extra daemon is required.

## Quick start

Six commands on a freshly installed VPS: four install, two prove it works.

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/nexwinds/mx-backup-mailcow.git
cd mx-backup-mailcow
sudo bash install.sh --local-dir .
sudo mx-diagnose                # health summary + report file
sudo mx-diagnose --stdout       # view the full report
```

| Command | What it does                                                                                   |
| ------- | ---------------------------------------------------------------------------------------------- |
| 1       | installs `git`, the only prerequisite                                                          |
| 2       | downloads the project                                                                          |
| 3       | enters the project directory                                                                   |
| 4       | runs the installer against this checkout (`--local-dir .`), which avoids downloading a release |
| 5       | prints a short health summary and writes the full report; the last line is the report path     |
| 6       | prints that full report, for a closer look or to paste into a ticket                           |

The report is read-only and safe to share. Command 5 prints its path, so it can
also be copied: `scp root@mx2.example.com:<path> .`

Before running command 4 you need a read-only API key from the Mailcow
interface: one browser step, described in
[Get the Mailcow API key](#get-the-mailcow-api-key).

The installer asks only these questions:

```text
Postfix hostname for this server (FQDN): mx2.example.com
Mailcow hostname (API endpoint): mail.example.com
Primary Mailcow IP address: 203.0.113.10
Read-only API key:                 (input hidden)
Private CA file for the API (optional):
Inbound TLS certificate chain (blank: no STARTTLS): /etc/letsencrypt/live/mx2.example.com/fullchain.pem
Inbound TLS private key: /etc/letsencrypt/live/mx2.example.com/privkey.pem
Forward root/postmaster mail to (blank: discard):
SMTP TLS mode for the primary (secure/may): secure
```

`secure` is the default because the hop that carries queued mail must
authenticate the primary; `may` is accepted only as an explicit choice and is
reported as unverified. It also prints a summary and the next DNS steps when it
finishes.

Once the first GitHub Release is published, the two-command alternative becomes
available:

```bash
curl -fsSL -o install.sh \
  https://github.com/nexwinds/mx-backup-mailcow/releases/latest/download/install.sh
sudo bash install.sh
```

## Quick update

Ubuntu packages and the application are updated separately, then verified. Once
the first GitHub Release exists:

```bash
sudo mx-update                  # Ubuntu packages; never reboots or dist-upgrades
sudo mx-update-scripts --check  # is a newer application release available?
sudo mx-update-scripts          # install it (checksum-verified, rollback-able)
sudo mx-diagnose                # summary + fresh report
```

Until the first release is published, update from the checkout instead:

```bash
cd mx-backup-mailcow
git pull
sudo bash install.sh --local-dir .
sudo mx-diagnose
```

`install.sh` is idempotent: it keeps the API key, unmanaged configuration lines,
maps, queues and logs. If a reboot is required, `mx-update` reports it; reboot in
a maintenance window.

On the **Mailcow host**, re-run the allowlist script after each Mailcow update so
postscreen and rspamd keep trusting this server:

```bash
cd /opt/mailcow-dockerized
sudo apt update && sudo apt upgrade -y
./update.sh
sudo bash /root/allowlist-backup-mx.sh
```

See [Allow the backup MX in Mailcow](#allow-the-backup-mx-in-mailcow) for the
first run and for `--check`/`--remove`.

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

Do **not** enable Mailcow's own "relay this domain" feature for domains that the
backup MX serves; the backup MX synchronizes recipients directly.

## Check the health in one minute

```bash
sudo mx-diagnose
```

It prints a short summary — Postfix, queue, timer, last synchronization, domains
and mailboxes, inbound/outbound TLS, queue disk — and then the path of the full
report as the last line. Read the verdict first:

| Summary says                      | Meaning                                                   |
| --------------------------------- | --------------------------------------------------------- |
| `Assessment: healthy`             | nothing obvious is wrong                                  |
| `Assessment: needs attention`     | read the `Attention` bullets directly below it            |
| `Postfix: inactive`               | Postfix is not running; check the journal                 |
| `Queue: 0 messages`               | nothing is waiting for the primary                        |
| queue grows while primary is down | normal: mail is queued and retried every 5–15 minutes     |
| `Last sync: ok via api, 4m ago`   | the maps are current                                      |
| `Last sync: degraded via cache`   | the API failed; cached maps still accept mail             |
| `Last sync: never`                | no synchronization has succeeded; check the API key first |
| `Inbound STARTTLS: disabled`      | senders enforcing MTA-STS or DANE cannot deliver          |
| `Queue disk: 9x% used`            | free space or clear the queue before it fills             |

To view the whole report, run `sudo mx-diagnose --stdout`. To copy it, use the
path from the last line:

```bash
scp root@mx2.example.com:/var/log/mailcow-backup-mx/diagnostics/health-*.md .
```

The report is read-only (mode `0600`) and safe to attach to a ticket or an AI
assistant. Raw one-line checks, report sections and every flag are in
[`OPERATIONS.md`](OPERATIONS.md#check-the-health-of-the-server) and
[`DOCS.md`](DOCS.md#diagnosesh).

## What it does

- **Postfix-only backup MX.** Receives SMTP on port 25, validates recipients,
  queues mail and relays it directly to the primary Mailcow IP.
- **Automatic synchronization.** Domains and recipients are read from the
  Mailcow REST API every two hours with a read-only, IP-restricted key.
- **Safe updates.** Maps are staged, validated and installed atomically; a failed
  sync never destroys the maps in use, and falls back to cached data.
- **Bounded acceptance.** Only active Mailcow domains and known recipients are
  relayed; `@domain` wildcards cover catch-all and alias domains.
- **Prolonged-outage mode.** After seven days without a sync, hosted domains
  accept all recipients so newly created addresses are not rejected; strict
  validation returns on the next successful sync.
- **Verified application updates.** Releases are SHA-256 checked, syntax-checked
  and rollback-able; diagnostics are read-only and redact credentials.
- **No mailbox hosting.** No IMAP, POP3, webmail or local mailboxes.

Architecture, DNS/firewall, configuration, releases and security notes live in
[`OPERATIONS.md`](OPERATIONS.md).

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
source, provided the copyright notice and permission text in [`LICENSE`](LICENSE)
stay with the software.

Copyright (c) 2026 **Nexwinds Solutions Lda**, registered in Portugal —
<https://nexwinds.com>.
