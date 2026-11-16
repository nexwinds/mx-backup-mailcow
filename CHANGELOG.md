# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

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
