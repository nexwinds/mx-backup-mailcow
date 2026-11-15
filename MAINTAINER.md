# mx-backup-mailcow — maintainer guide

Audience: whoever cuts and publishes releases. For operating a server, see
[`README.md`](README.md); for a deployment without the installer, see
[`MANUAL-SETUP.md`](MANUAL-SETUP.md); for development, tests and pull request
rules, see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Project status

Pre-release. `VERSION` and `CHANGELOG.md` already describe `1.0.0`, but **no
GitHub Release or tag exists yet**: the first release is published when the
application is declared stable. Consequences while in this state:

- `install.sh` without `--local-dir` fails, because it bootstraps
  `https://api.github.com/repos/nexwinds/mx-backup-mailcow/releases/latest`.
- `update-scripts.sh` (`mx-update-scripts`) has nothing to fetch.
- Users install with `sudo bash install.sh --local-dir .` from a checkout.

## Repository layout

```text
VERSION  README.md  DOCS.md  MANUAL-SETUP.md  CONTRIBUTING.md
MAINTAINER.md  CHANGELOG.md  CODE_OF_CONDUCT.md  LICENSE  Makefile
package.json  bunfig.toml  .editorconfig
install.sh  sync-mailcow.sh  update.sh  diagnose.sh  update-scripts.sh
systemd/  config/  logrotate/  scripts/build-release.sh
tests/  .github/workflows/  .github/ISSUE_TEMPLATE/  .github/PULL_REQUEST_TEMPLATE.md
```

This is the source tree. The paths a deployed server has are in
[`DOCS.md`](DOCS.md#runtime-layout).

| Path                               | Role                                                                         |
| ---------------------------------- | ---------------------------------------------------------------------------- |
| `install.sh`                       | provisioner; also the bootstrap asset of a release                           |
| `sync-mailcow.sh`                  | API → Postfix map synchronization                                            |
| `update.sh`                        | Ubuntu package updates (`mx-update`)                                         |
| `diagnose.sh`                      | read-only health report (`mx-diagnose`)                                      |
| `update-scripts.sh`                | self-updater from Releases (`mx-update-scripts`)                             |
| `scripts/build-release.sh`         | reproducible release archive + manifests                                     |
| `tests/`                           | offline test suite with mocked commands                                      |
| `CONTRIBUTING.md`                  | what an outside contributor needs: scope, setup, tests, PR rules             |
| `DOCS.md`                          | lookup material: runtime paths, configuration keys, script flags, map tables |
| `CODE_OF_CONDUCT.md`               | Contributor Covenant 2.1                                                     |
| `.github/workflows/ci.yml`         | lint, tests, release build on every push/PR                                  |
| `.github/workflows/pr-title.yml`   | Conventional Commit check on pull request titles                             |
| `.github/workflows/release.yml`    | tag-triggered release publication                                            |
| `.github/ISSUE_TEMPLATE/`          | bug report and feature request forms                                         |
| `.github/PULL_REQUEST_TEMPLATE.md` | pull request checklist                                                       |
| `package.json`, `bunfig.toml`      | formatter entry points for `bun run format`; no dependencies, no CI job      |

There is no `dist/` in the tree: `make release` creates it on demand and it is
ignored by git. Release artifacts are published from CI, never committed.

Each script is standalone: no shared library, no `source` between scripts.
Every script reads paths from `MXB_*` environment variables with production
defaults, which is what makes the tests possible.

## Contributor workflow

Contributor-facing material lives in [`CONTRIBUTING.md`](CONTRIBUTING.md):
scope and acceptance test, development setup, test matrix, code rules, commit
and pull request conventions, review expectations and licensing. This document
covers only what a maintainer needs to cut and publish a release.

## Continuous integration

`ci.yml` runs on every push to `main`/`master` and on pull requests:

1. `make lint` (requires `shellcheck` and `jq`);
2. `make test`;
3. `make release` into `dist/`;
4. `sha256sum -c SHA256SUMS` on the produced assets.

`pr-title.yml` runs on pull request `opened`, `edited`, `synchronize` and
`reopened` events and rejects titles that are not a Conventional Commit
(`type(scope): subject`). It uses no third-party action: the check is a Bash
regular expression over the title. The allowed types and scopes are documented
in [`CONTRIBUTING.md`](CONTRIBUTING.md#commit-messages-and-pull-request-titles).
Someone merging through the web UI must therefore keep the pull request title
intact; a squash merge already uses it.

`release.yml` runs only on a `v*` tag push and has write permission on
repository contents. In order:

1. checks out the tag;
2. verifies the tag against `VERSION` (`v<VERSION>` must equal the tag name);
3. runs `make lint` and `make test`;
4. builds the assets with `make release`;
5. verifies the checksums;
6. publishes the GitHub Release with `gh release create --generate-notes`.

A tag that does not match `VERSION` fails the workflow, so bump
`VERSION` **before** tagging.

## Versioning and changelog

- Semantic Versioning (`MAJOR.MINOR.PATCH`) in the single-line `VERSION` file.
  Every script reads it, and the release workflow compares it to the tag.
- `CHANGELOG.md` follows Keep a Changelog. Add an entry for every release;
  keep `[Unreleased]` at the top while a cycle is open.
- `VERSION` is embedded into the published `install.sh` (the placeholder
  `VERSION="0.0.0-dev"` is replaced at build time), so a downloaded installer
  reports the release it belongs to even without an adjacent `VERSION` file.

## Building a release locally

```bash
make release
cat dist/SHA256SUMS
```

`scripts/build-release.sh` produces:

```text
dist/mx-backup-mailcow-<version>.tar.gz   staged tree: bin/, systemd/, share/doc/, config/, logrotate/
dist/SHA256SUMS                           checksums for the archive and install.sh
dist/install.sh                           standalone bootstrap installer
```

Details that matter when modifying the build:

- the staged tree must contain `bin/{install,sync-mailcow,update,diagnose,update-scripts}.sh`,
  `VERSION`, both systemd units, `share/doc/README.md`, `share/doc/CHANGELOG.md`,
  `share/doc/LICENSE` (no extension), `config/config.example` and
  `logrotate/mailcow-backup-mx`;
- `DOCS.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `MAINTAINER.md` and
  `MANUAL-SETUP.md` are **not** staged yet: add them to
  `scripts/build-release.sh` (and to the expected layout in
  `tests/test-release.sh`) before the first release, so an installed server
  keeps its own copy of the documentation;
- the archive embeds its own `SHA256SUMS`, which both `install.sh` and
  `update-scripts.sh` verify after extraction;
- archive paths must stay relative (`tar` is called with `-C` and no absolute
  paths) because both consumers reject `..` and leading `/`;
- the outer `SHA256SUMS` covers the archive and `install.sh`, which is what
  `--sha256` and the documented `curl` download verify.

Builds are reproducible: `tar --sort=name --owner=0 --group=0 --numeric-owner`
with a fallback for platforms whose `tar` lacks those flags.

## Publishing a release

Publishing is the step that makes installation possible without `--local-dir`.

1. Make sure the tree is green: `make lint && make test` and
   `bun run format:check`.
2. Set the version:

   ```bash
   printf '1.0.0\n' > VERSION
   ```

3. Move the `CHANGELOG.md` entries from `[Unreleased]` into `## [1.0.0] - YYYY-MM-DD`.
4. Commit and push.
5. Create the tag and push it:

   ```bash
   git tag -a v1.0.0 -m "v1.0.0"
   git push origin v1.0.0
   ```

6. Watch the `Release` workflow. It verifies the tag against `VERSION`, runs
   the tests, builds and publishes these assets:
   - `mx-backup-mailcow-1.0.0.tar.gz`
   - `SHA256SUMS`
   - `install.sh`
7. Verify the published artifacts from a clean directory:

   ```bash
   curl -fsSLO https://github.com/nexwinds/mx-backup-mailcow/releases/download/v1.0.0/SHA256SUMS
   curl -fsSLO https://github.com/nexwinds/mx-backup-mailcow/releases/download/v1.0.0/mx-backup-mailcow-1.0.0.tar.gz
   sha256sum -c SHA256SUMS
   ```

For an offline or pre-release installation, users pass `--local-dir`; that path
never contacts GitHub and is the only option until the first tag exists.

If a release is wrong, delete the tag and release, fix the tree, bump the
version and tag again. Do not re-tag the same version with different content:
`update-scripts.sh` and the manifests assume a version identifies one tree.

## Deferred simplifications

Recorded so the decisions are not relitigated by accident. None of these are
required for correctness; each would reduce surface area.

| Item                                                                            | Why it is a candidate                                                                                                                                                                    |
| ------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `update-scripts.sh` (492 lines)                                                 | release listing, semver comparison, forced downgrade, backup pruning, self-verification re-exec and per-version rollback duplicate what `git pull` + `install.sh --local-dir` already do |
| `update.sh` (239 lines)                                                         | `apt upgrade` plus reboot-state bookkeeping; `unattended-upgrades` covers the same ground                                                                                                |
| release bootstrap in `install.sh` (`--release`, `--sha256`, `/releases/latest`) | forces the publish-before-install order and is the most fragile part of the install; installing the checkout is simpler                                                                  |
| relaxation after `RELAX_AFTER_DAYS`                                             | a backup MX that starts accepting every recipient after a week weakens the "bounded acceptance" guarantee                                                                                |
| AI prompt in `diagnose.sh`                                                      | a technician needs the verdict, not an analysis prompt; the prompt stays as long as the report is shared with an AI assistant                                                            |
| `--verbose` in `sync-mailcow.sh`                                                | accepted but does nothing                                                                                                                                                                |
| `--quiet` in four scripts                                                       | rarely used from the timer, which already logs to a file                                                                                                                                 |
| `MXB_*` override list in DOCS.md                                                | environment variables exist for tests and staging, not for normal operation                                                                                                              |

## Conventions

Code, test and documentation rules are in
[`CONTRIBUTING.md`](CONTRIBUTING.md#making-a-change); they apply to maintainer
commits exactly as they apply to outside contributors. The only
maintainer-specific rule is that a release must be cut from a tree where
`make lint && make test` passes, and the tag must match `VERSION`.
