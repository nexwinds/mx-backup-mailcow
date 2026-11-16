# Troubleshooting

Symptom-first fixes for **mx-backup-mailcow**. For procedures and background see
[`OPERATIONS.md`](OPERATIONS.md); for flags and data formats see
[`DOCS.md`](DOCS.md). Start every investigation with:

```bash
sudo mx-diagnose
```

It prints a short summary and writes the full report. Read `Assessment` and the
`Attention` bullets first, then the report sections named in the table below.

## Common problems

| Symptom                                                   | Check                                                                                                         | Action                                                                        |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `API authentication failed (HTTP 401/403)`                | Mailcow API key, read-only flag, IP allowlist                                                                 | Recreate the key with the correct IP; run `sync-mailcow.sh`                   |
| `... is not a fully qualified domain name`                | `hostname -f`                                                                                                 | `hostnamectl set-hostname mx2.example.com`, add it to `/etc/hosts`, re-run    |
| `the system clock is not synchronized`                    | `timedatectl timesync-status`, `systemctl status systemd-timesyncd`                                           | Let NTP sync, then re-run; do not skip the check                              |
| `cannot verify TLS to the primary`                        | `openssl s_client -starttls smtp -connect <ip>:25 -servername <name>`                                         | Fix the primary chain, or choose `--smtp-tls-mode may` knowingly              |
| `inbound STARTTLS is configured but not advertised`       | `postconf -h smtpd_tls_cert_file smtpd_tls_key_file`, Postfix journal                                         | Re-run `install.sh` to re-stage the chain/key                                 |
| `the backup MX did not accept the synchronized recipient` | `postmap -q user@domain hash:/etc/postfix/mailcow-backup-mx/relay_recipients`, `postconf -F smtp/inet/chroot` | Re-run `install.sh` (fixes chroot/map visibility)                             |
| `TLS verification failed`                                 | Certificate chain of the Mailcow API                                                                          | Supply the private CA with `--ca-file`; do not disable verification           |
| `Postfix parameter ... does not reference`                | `postconf -h relay_domains relay_recipient_maps transport_maps`                                               | Re-run `install.sh`                                                           |
| Unknown recipient is accepted                             | `postmap -q user@domain hash:/etc/postfix/mailcow-backup-mx/relay_recipients`                                 | Check Mailcow active state; `sync-mailcow.sh --dry-run`                       |
| Known recipient is rejected                               | Map contents, `EXCLUDE_DOMAINS`, source domain active                                                         | Run a sync with `--force` after verifying the API output                      |
| Queue grows while the primary is down                     | `postqueue -p`, `postfix status`                                                                              | Verify the primary IP/port and outbound TCP/25; Postfix retries automatically |
| Mail expires                                              | `maximal_queue_lifetime` and outage duration                                                                  | Increase `QUEUE_LIFETIME` in the config only if justified                     |
| Timer does not run                                        | `systemctl list-timers`, `systemctl status`                                                                   | `systemctl enable --now mailcow-sync.timer`                                   |
| Maps not applied                                          | `sync-mailcow.sh` log, `postfix status`                                                                       | The script reloads Postfix only when a map or its index changed               |
| Installer cannot download a release                       | Repository/release exists, outbound HTTPS                                                                     | Use `--local-dir` or `--release`                                              |
| `update-scripts` rate limited                             | GitHub API quota                                                                                              | Retry later or use `--release VERSION`                                        |

## Summary verdicts

| Summary line                                           | Meaning                                                          |
| ------------------------------------------------------ | ---------------------------------------------------------------- |
| `Assessment: healthy`                                  | nothing obvious is wrong                                         |
| `Assessment: needs attention`                          | read the `Attention` bullets directly below it                   |
| `Postfix: inactive`                                    | Postfix is not running; start it and read the Postfix journal    |
| `Queue: N messages`                                    | mail is waiting; normal during an outage, suspicious otherwise   |
| `Sync timer: inactive`                                 | the two-hour synchronization is not scheduled                    |
| `Last sync: ok via api, ...`                           | the maps are current                                             |
| `Last sync: degraded via cache, ...`                   | Mailcow was unreachable; cached maps still accept mail           |
| `Last sync: never`                                     | no synchronization has succeeded; check the API key first        |
| `Inbound STARTTLS: disabled`                           | senders enforcing MTA-STS or DANE cannot deliver                 |
| `Outbound SMTP TLS: may (unverified)`                  | the forward hop does not authenticate the primary                |
| `Queue disk: 9x% used`                                 | free space or clear the queue before it fills                    |
| `the last successful Mailcow sync is over 4 hours old` | the API or the key is failing; the server is on cache            |
| `recipient validation is relaxed`                      | seven days without a sync; invalid recipients are rejected later |

## Diagnostics

```bash
sudo mx-diagnose              # summary first, report path last
sudo mx-diagnose --stdout     # full report on stdout; summary on stderr
sudo journalctl -u mailcow-sync.service -n 100 --no-pager
sudo tail -n 100 /var/log/mailcow-backup-mx/sync.log
```

Report sections map to the areas above:

| Section                            | Use it for                                                         |
| ---------------------------------- | ------------------------------------------------------------------ |
| 1. System                          | clock, disk, memory, failed units                                  |
| 2. Postfix                         | configuration, inbound STARTTLS, chroot/map visibility, RCPT probe |
| 3. Mailcow synchronization         | state file, cache age, map consistency, timer history              |
| 4. Connectivity                    | API reachability, TLS verification, primary SMTP banner            |
| 5. Security posture                | firewall, exposed services, file permissions                       |
| 6. Application version and updates | installed version, pending package updates, reboot marker          |
| 7. Recent system errors            | journal errors and the installer log                               |

To prove that recipient validation and queue recovery actually work, use the lab
checks in [`DOCS.md`](DOCS.md#verification-checks).
