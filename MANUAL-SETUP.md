# mx-backup-mailcow — manual setup

Audience: whoever cannot run `install.sh` — a different provisioning system, an
appliance, a configuration-management role, or a server that is not a fresh
Ubuntu 24.04. Also the reference for understanding exactly what the installer
changes.

This page describes the same design, by hand. It creates no new configuration
keys and uses no undocumented behaviour: every value below is what `install.sh`
sets. If you follow it, you get the same running server.

**Scope and honesty:** the installer is the tested path (`tests/test-install.sh`).
A manual deployment is not covered by the test suite, is not migrated
automatically by `install.sh`, and is yours to maintain. If you later run
`install.sh`, it rewrites the managed keys in the configuration file and the
Postfix settings listed below, preserving only unmanaged lines and the existing
API key.

## Reference layout

The paths this deployment creates, with their modes, are listed once in
[`DOCS.md`](DOCS.md#runtime-layout). The steps below create them.

## Step 1 — Packages

Preseed Postfix first, so it is installed without an interactive configuration
step:

```bash
sudo debconf-set-selections <<EOF
postfix postfix/main_mailer_type select No configuration
postfix postfix/mailname string $(hostname -f)
EOF
```

```bash
sudo apt-get update
sudo apt-get install -y postfix curl jq ca-certificates ufw logrotate
```

`ufw` is optional. If you use another firewall, configure it as described in
Step 9 below.

## Step 2 — Directories

The modes matter: the API key lives in a `0600` file inside a `0750` directory.

```bash
sudo install -d -m 0750 /etc/mailcow-backup-mx
sudo install -d -m 0750 /var/lib/mailcow-backup-mx
sudo install -d -m 0750 /var/lib/mailcow-backup-mx/{state,cache,run,tmp}
sudo install -d -m 0750 /var/log/mailcow-backup-mx
sudo install -d -m 0750 /var/log/mailcow-backup-mx/diagnostics
sudo install -d -m 0700 /var/backups/mx-backup-mailcow
sudo install -d -m 0755 /etc/postfix/mailcow-backup-mx
sudo install -d -m 0755 /opt/mx-backup-mailcow/{bin,systemd,share/doc,config}
```

## Step 3 — Configuration file

Create `/etc/mailcow-backup-mx/config` by copying
[`config/config.example`](config/config.example) with a `0600` mode, then
editing it:

```bash
sudo install -m 0600 -o root -g root config/config.example /etc/mailcow-backup-mx/config
sudoedit /etc/mailcow-backup-mx/config
```

The complete key list, with defaults and the `MXB_*` path overrides, is in
[`DOCS.md`](DOCS.md#configuration). The file is sourced as shell, so quote
values that contain spaces. Obtain the API key as described in
[`README.md`](README.md#get-the-mailcow-api-key).

## Step 4 — Application scripts

Copy the five scripts and the documentation from the checkout:

```bash
sudo install -m 0755 install.sh sync-mailcow.sh update.sh diagnose.sh update-scripts.sh \
  /opt/mx-backup-mailcow/bin/
sudo install -m 0644 VERSION /opt/mx-backup-mailcow/VERSION
sudo install -m 0644 README.md CHANGELOG.md LICENSE /opt/mx-backup-mailcow/share/doc/
sudo install -m 0644 systemd/mailcow-sync.service systemd/mailcow-sync.timer \
  /opt/mx-backup-mailcow/systemd/
sudo install -m 0644 logrotate/mailcow-backup-mx /opt/mx-backup-mailcow/
sudo install -m 0644 config/config.example /opt/mx-backup-mailcow/config/
( cd /opt/mx-backup-mailcow && find bin -type f -name '*.sh' -print0 | sort -z \
    | xargs -0 sha256sum > SHA256SUMS )
```

Create the command symlinks used by the documentation and the systemd unit:

```bash
sudo ln -sfn /opt/mx-backup-mailcow/bin/sync-mailcow.sh  /usr/local/sbin/sync-mailcow
sudo ln -sfn /opt/mx-backup-mailcow/bin/update.sh        /usr/local/sbin/mx-update
sudo ln -sfn /opt/mx-backup-mailcow/bin/diagnose.sh      /usr/local/sbin/mx-diagnose
sudo ln -sfn /opt/mx-backup-mailcow/bin/update-scripts.sh /usr/local/sbin/mx-update-scripts
```

Sanity check before going further — all five scripts must parse:

```bash
for f in /opt/mx-backup-mailcow/bin/*.sh; do bash -n "$f" || echo "FAIL $f"; done
```

## Step 5 — Postfix

If the postfix package was installed with the "No configuration" mailer type,
it prints `Postfix (main.cf) was not set up` and `/etc/postfix/main.cf` does not
exist. Restore the package templates first, otherwise every `postconf` command
below fails:

```bash
test -e /etc/postfix/main.cf || sudo cp /usr/share/postfix/main.cf.debian /etc/postfix/main.cf
test -e /etc/postfix/master.cf || sudo cp /usr/share/postfix/master.cf.dist /etc/postfix/master.cf
```

Back up the original configuration once:

```bash
sudo cp -p /etc/postfix/main.cf /etc/postfix/main.cf.pre-mx-backup-mailcow
```

Apply the settings. A `compatibility_level` below `2` selects Postfix's
backwards-compatible legacy defaults (Postfix reports the compiled-in default
`0` when `main.cf` does not set one), so the snippet below raises it to `3.6`:

```bash
compat=$(postconf -h compatibility_level 2>/dev/null || true)
[[ "$compat" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( ${compat%%.*} >= 2 )) || compat=3.6
sudo postconf -e "compatibility_level = $compat"
```

Then, replacing the placeholders (`mx2.example.com`, `example.com`,
`203.0.113.20` and the port/lifetime values) with your own:

```bash
sudo postconf -e 'myhostname = mx2.example.com'
sudo postconf -e 'mydomain = example.com'
sudo postconf -e 'myorigin = $myhostname'
sudo postconf -e 'mydestination = localhost, localhost.localdomain'
sudo postconf -e 'inet_interfaces = all'
sudo postconf -e 'inet_protocols = all'
sudo postconf -e 'mynetworks_style = host'
sudo postconf -e 'mynetworks = 127.0.0.0/8 [::1]/128'
sudo postconf -e 'biff = no'
sudo postconf -e 'append_dot_mydomain = no'
sudo postconf -e 'smtpd_banner = $myhostname ESMTP'
sudo postconf -e 'relayhost ='
sudo postconf -e 'relay_domains = hash:/etc/postfix/mailcow-backup-mx/relay_domains'
sudo postconf -e 'relay_recipient_maps = hash:/etc/postfix/mailcow-backup-mx/relay_recipients'
sudo postconf -e 'transport_maps = hash:/etc/postfix/mailcow-backup-mx/transport'
sudo postconf -e 'smtp_tls_policy_maps = hash:/etc/postfix/mailcow-backup-mx/smtp_tls_policy'
sudo postconf -e 'alias_maps = hash:/etc/postfix/mailcow-backup-mx/aliases'
sudo postconf -e 'alias_database = hash:/etc/postfix/mailcow-backup-mx/aliases'
sudo postconf -e 'local_recipient_maps ='
sudo postconf -e 'virtual_alias_maps ='
sudo postconf -e 'virtual_mailbox_domains ='
sudo postconf -e 'virtual_mailbox_maps ='
sudo postconf -e 'smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination'
sudo postconf -e 'smtpd_recipient_restrictions = permit_mynetworks, reject_invalid_helo_hostname, reject_unauth_destination'
sudo postconf -e 'smtpd_client_restrictions ='
sudo postconf -e 'smtpd_sender_restrictions ='
sudo postconf -e 'smtpd_helo_required = yes'
sudo postconf -e 'smtpd_reject_unlisted_recipient = yes'
sudo postconf -e 'smtpd_forbid_bare_newline = yes'
sudo postconf -e 'smtpd_data_restrictions = reject_unauth_pipelining'
sudo postconf -e 'disable_vrfy_command = yes'
sudo postconf -e 'smtpd_sasl_auth_enable = no'
sudo postconf -e 'relay_domains_reject_code = 550'
sudo postconf -e 'unknown_relay_recipient_reject_code = 550'
sudo postconf -e 'parent_domain_matches_subdomains ='
sudo postconf -e 'recipient_delimiter = +'
sudo postconf -e 'maximal_queue_lifetime = 7d'
sudo postconf -e 'bounce_queue_lifetime = 1d'
sudo postconf -e 'queue_run_delay = 300s'
sudo postconf -e 'minimal_backoff_time = 600s'
sudo postconf -e 'maximal_backoff_time = 1800s'
sudo postconf -e 'delay_warning_time = 4h'
sudo postconf -e 'message_size_limit = 104857600'
sudo postconf -e 'mailbox_size_limit = 0'
sudo postconf -e 'smtpd_tls_security_level = may'
sudo postconf -e 'smtpd_tls_protocols = >=TLSv1.2'
sudo postconf -e 'smtp_tls_security_level = may'
sudo postconf -e 'smtp_tls_protocols = >=TLSv1.2'
sudo postconf -e 'smtp_tls_loglevel = 1'
sudo postconf -e 'smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt'
```

Local operational mail is discarded, so the server never stores mail:

```bash
sudo tee /etc/postfix/mailcow-backup-mx/aliases >/dev/null <<'EOF'
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
sudo chmod 0644 /etc/postfix/mailcow-backup-mx/aliases
sudo postmap hash:/etc/postfix/mailcow-backup-mx/aliases
```

Seed the four synchronized maps empty, so Postfix can start before the first
sync:

```bash
for name in relay_domains relay_recipients transport smtp_tls_policy; do
  sudo touch "/etc/postfix/mailcow-backup-mx/$name"
  sudo chmod 0644 "/etc/postfix/mailcow-backup-mx/$name"
  sudo postmap "hash:/etc/postfix/mailcow-backup-mx/$name"
done
```

Enable and reload Postfix:

```bash
sudo systemctl enable postfix
sudo systemctl reload postfix || sudo systemctl start postfix
sudo postfix check
```

## Step 6 — Map formats

All maps are `hash:` maps: tab-separated `key<TAB>value`, one entry per line.
`sync-mailcow.sh` writes them; do not edit them by hand unless you are repairing
a broken server, because the next sync rewrites them.

| File               | Entry                                                 | Meaning                                                                                                   |
| ------------------ | ----------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `relay_domains`    | `example.com<TAB>OK`                                  | domain is relayed                                                                                         |
| `relay_recipients` | `alice@example.com<TAB>OK`                            | exact recipient accepted                                                                                  |
| `relay_recipients` | `@example.com<TAB>OK`                                 | every recipient of the domain accepted (catch-all, alias domain, `relay_all_recipients`, or relaxed mode) |
| `transport`        | `example.com<TAB>smtp:[203.0.113.10]:25`              | delivery target is the primary IP, never MX                                                               |
| `smtp_tls_policy`  | `[203.0.113.10]:25<TAB>may`                           | opportunistic TLS to the primary                                                                          |
| `smtp_tls_policy`  | `[203.0.113.10]:25<TAB>secure match=mail.example.com` | mandatory TLS with certificate name                                                                       |

Example of the pair that matters most:

```text
# relay_domains
example.com	OK
alias.example	OK

# transport
example.com	smtp:[203.0.113.10]:25
alias.example	smtp:[203.0.113.10]:25

# relay_recipients
alice@example.com	OK
bob@example.com	OK
@alias.example	OK
```

After any manual edit of a text map, rebuild the index and reload Postfix:

```bash
sudo postmap hash:/etc/postfix/mailcow-backup-mx/relay_recipients
sudo postfix reload
```

## Step 7 — systemd units

`/etc/systemd/system/mailcow-sync.service`:

```ini
[Unit]
Description=Mailcow Backup MX domain and recipient synchronization
Documentation=https://github.com/nexwinds/mx-backup-mailcow
After=network-online.target postfix.service
Wants=network-online.target
ConditionPathExists=/etc/mailcow-backup-mx/config

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sync-mailcow
Nice=10
IOSchedulingClass=best-effort
TimeoutStartSec=15min
PrivateTmp=yes
ProtectHome=yes
NoNewPrivileges=yes
SyslogIdentifier=mailcow-sync
```

`/etc/systemd/system/mailcow-sync.timer`:

```ini
[Unit]
Description=Run the Mailcow Backup MX synchronization every two hours

[Timer]
OnCalendar=*-*-* 00/2:15:00
RandomizedDelaySec=10m
AccuracySec=1m
Persistent=true
Unit=mailcow-sync.service

[Install]
WantedBy=timers.target
```

Install and start them:

```bash
sudo install -m 0644 /opt/mx-backup-mailcow/systemd/mailcow-sync.service /etc/systemd/system/
sudo install -m 0644 /opt/mx-backup-mailcow/systemd/mailcow-sync.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mailcow-sync.timer
```

`ConditionPathExists` means the service is a no-op until the configuration file
exists, so the order of the steps above is not critical.

## Step 8 — Log rotation

`/etc/logrotate.d/mailcow-backup-mx`:

```text
/var/log/mailcow-backup-mx/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
```

```bash
sudo install -m 0644 /opt/mx-backup-mailcow/mailcow-backup-mx /etc/logrotate.d/mailcow-backup-mx
```

## Step 9 — Firewall

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'      # or your SSH port
sudo ufw allow 25/tcp comment 'SMTP backup MX'
sudo ufw enable
```

Do not enable UFW before the SSH rule is in place. The installer detects the
SSH port from `/etc/ssh/sshd_config` and `/etc/ssh/sshd_config.d/*.conf` and
refuses to enable the firewall when it cannot determine one; by hand, check the
port yourself with `sshd -T | grep '^port'`.

## Step 10 — First synchronization and health check

```bash
sudo /opt/mx-backup-mailcow/bin/sync-mailcow.sh --dry-run   # preview
sudo /opt/mx-backup-mailcow/bin/sync-mailcow.sh             # install maps
sudo mx-diagnose --stdout | head -n 40
```

Then continue with [Check the health of the server](README.md#check-the-health-of-the-server)
in the README, which applies unchanged to a manual deployment.

## Verification

These checks require a lab or a maintenance window.

Recipient validation (from an external host):

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

Using `telnet`/`openssl s_client`:

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

Queue recovery test (lab only):

1. Stop Postfix on the primary (or block TCP/25).
2. Send a message to a valid recipient on a hosted domain.
3. `postqueue -p` shows one deferred message.
4. Restore the primary.
5. Within 5–15 minutes the queue empties; or run `sudo postqueue -f`.
6. Confirm the message in the recipient's mailbox.

Because no MTA is started during development, recipient acceptance is also
verified against a simulator that implements the documented Postfix lookup
order; the manual SMTP checks above are the confirmation before production use.

## Updating a manual deployment

Before the first GitHub Release exists, pull the repository and copy the scripts
again:

```bash
cd mx-backup-mailcow
git pull
sudo install -m 0755 sync-mailcow.sh update.sh diagnose.sh update-scripts.sh install.sh \
  /opt/mx-backup-mailcow/bin/
sudo systemctl daemon-reload    # only if unit files changed
```

Rebuild `/opt/mx-backup-mailcow/SHA256SUMS` with the command from Step 4, so
the installed tree keeps a manifest that matches the new scripts.

The configuration file, the maps, the queue and the logs are never part of an
update: leave them alone. After a release exists, prefer
`sudo mx-update-scripts`, which performs the same swap with checksum
verification, a backup and a rollback path.

## Environment overrides

Every path can be overridden for staging, tests or a non-standard layout. The
variable names and the production defaults are listed in
[`DOCS.md`](DOCS.md#configuration).

Example: run the synchronization against a staging prefix without touching the
real server.

```bash
MXB_ETC=/tmp/mx-test/etc MXB_MAPS_DIR=/tmp/mx-test/maps \
MXB_STATE_DIR=/tmp/mx-test/state MXB_LOG_DIR=/tmp/mx-test/log \
  sudo -E bash sync-mailcow.sh --dry-run
```

## Differences from install.sh

| Aspect                  | Manual                       | `install.sh`                                                  |
| ----------------------- | ---------------------------- | ------------------------------------------------------------- |
| Postfix `main.cf`       | edited by the commands above | same values via `postconf -e`, plus a one-time backup         |
| Configuration file      | created by you               | written with mode `0600`, managed keys rewritten on every run |
| Package upgrade         | your choice                  | `apt-get upgrade` unless `--skip-upgrade`                     |
| Firewall                | your choice of manager       | UFW, SSH port detected, TCP/25 opened                         |
| Initial synchronization | one command                  | performed automatically, failure leaves the timer enabled     |
| Idempotency             | your responsibility          | re-running preserves the key and unmanaged lines              |
| Checksums               | optional                     | release archive and inner manifest verified                   |

If you build your own automation, keep the two invariants that make the design
safe: maps are built in a staging directory and installed atomically, and
Postfix is reloaded only when a map or its index changed.
