# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

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
