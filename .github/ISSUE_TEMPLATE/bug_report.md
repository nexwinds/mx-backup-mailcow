---
name: Bug report
about: The installer, synchronization, updater or diagnostics does not behave as documented
title: "fix(scope): "
labels: bug
assignees: ""
---

<!--
Do not paste API keys, private keys, passwords or real message content.
`mx-diagnose` already redacts credentials and masks addresses, so prefer its
output over raw logs.
-->

## What happened

<!-- The observable behaviour, including the exact command and the full error. -->

## What you expected

<!-- The behaviour documented in README.md or MANUAL-SETUP.md. Quote the line. -->

## Steps to reproduce

1.
2.
3.

## Environment

| Item                                                   | Value                                   |
| ------------------------------------------------------ | --------------------------------------- |
| Project version (`cat /opt/mx-backup-mailcow/VERSION`) |                                         |
| Ubuntu version (`lsb_release -ds`)                     |                                         |
| Installed with                                         | `install.sh` / `install.sh --local-dir` |
| Postfix version (`postconf mail_version`)              |                                         |
| Mailcow version                                        |                                         |
| Was the primary Mailcow reachable when it failed?      | yes / no / unknown                      |

## Diagnostics

```bash
sudo mx-diagnose --stdout
```

Paste at least section **3. Mailcow synchronization**, **2. Postfix** and
**7. Recent system errors**. Attach the whole file if you are unsure.

## Relevant log lines

```bash
sudo tail -n 50 /var/log/mailcow-backup-mx/sync.log
sudo journalctl -u mailcow-sync.service -n 50 --no-pager
```

## Anything else

<!-- Recent changes on the server, DNS or firewall edits, new domains, etc. -->
