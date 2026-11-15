# Changelog

All notable changes to this project are documented in this file. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project follows [Semantic Versioning](https://semver.org/).

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
