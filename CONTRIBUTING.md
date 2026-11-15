# Contributing to mx-backup-mailcow

Thanks for taking the time to improve the project. This document explains what
the project is for, what kinds of changes fit, how to build and test locally,
and what a pull request needs to contain.

It is written for someone who found the repository for the first time, and it is
also the checklist the maintainer follows. No prior context is assumed.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## What the project is for

mx-backup-mailcow is a backup MX: it accepts mail for synchronized domains on
port 25, queues it while the primary Mailcow is unreachable, and relays it to
the primary IP when it returns. It is a **single-purpose Postfix configuration
with a small set of standalone Bash scripts**, on plain Ubuntu 24.04.

The acceptance test for every change is stated by the project owner:

> The goal of MX Backup is to be lightweight, simple, reliable, secure, and
> responsive to the needs of what an MX Backup is; new features that deviate
> from this will be rejected.

In practice:

| Welcome                                                                         | Out of scope                                                             |
| ------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Postfix relay and recipient-validation correctness                              | databases, Redis, or any state store beyond `hash:` maps and JSON files  |
| synchronization robustness: API failures, cache, validation, atomic map install | container or orchestration packaging (Docker, Compose, Kubernetes, Helm) |
| clearer diagnostics and redaction                                               | a web UI, REST API, or control panel                                     |
| documentation, tests, packaging fixes for Ubuntu 24.04                          | mailbox hosting, IMAP, POP3, webmail, or message storage                 |
| security hardening that does not weaken TLS or recipient limits                 | spam filtering, antivirus, DKIM signing, or rewriting sender identity    |
| small operational fixes (log noise, exit codes, message wording)                | plugin systems, hook frameworks, or multi-tenant management              |

If your idea needs a new daemon, a new runtime dependency, a new configuration
key, or a new service beyond Postfix and systemd, **open an issue before
writing code**. The scope rule is the reason this project is still five scripts.

## Ways to contribute

| You want to            | Do this                                                                                                                          |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| report a bug           | open a [bug report](.github/ISSUE_TEMPLATE/bug_report.md)                                                                        |
| ask for a feature      | open a [feature request](.github/ISSUE_TEMPLATE/feature_request.md) and describe the operational problem, not the implementation |
| fix documentation      | open a pull request; documentation-only changes need no test                                                                     |
| send code              | open a pull request that follows this page                                                                                       |
| report a vulnerability | **do not** open a public issue; use the repository's _Security → Report a vulnerability_ tab                                     |

## Before you start

1. Read [`README.md`](README.md) if you are new to the project, and
   [`MANUAL-SETUP.md`](MANUAL-SETUP.md) for what the installer actually changes.
2. Search the existing issues and pull requests; a duplicate is closed quickly.
3. For anything that is not a one-line fix, open an issue first and wait for a
   maintainer to agree on the direction. It avoids work that scope will reject.
4. Keep one topic per pull request. Two unrelated fixes in one PR are two PRs.

## Development setup

There is nothing to build: the deliverable is the scripts themselves.

Requirements: `bash` and `git`. To run the full checks you also need `jq` and
`shellcheck`.

```bash
sudo apt-get install -y git shellcheck jq     # Ubuntu 24.04
git clone https://github.com/nexwinds/mx-backup-mailcow.git
cd mx-backup-mailcow
make lint
make test
```

On Windows (Git Bash), point the tests at a directory that contains `jq.exe`
and `shellcheck.exe`:

```bash
export MXB_TEST_TOOLS=/c/path/to/tools
make test
```

Individual tests can run directly; `tests/run-tests.sh` only adds
`MXB_TEST_TOOLS` to `PATH` and checks the required tools.

```bash
bash tests/test-sync.sh
bash tests/test-install.sh
```

The suite is offline and never touches the real system: every external command
(`curl`, `postmap`, `systemctl`, `apt-get`, …) is replaced by an exported Bash
function mock, and every path is redirected through `MXB_*` variables.

| Test file                      | Focus                                                                                                          |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| `tests/test-sync.sh`           | map content, counts, cache, idempotency, dry run, empty Mailcow, exclusions                                    |
| `tests/test-sync-failure.sh`   | API errors, invalid JSON, suspicious drops, postmap/reload failures, rollback, relaxation, invalid entries     |
| `tests/test-recipients.sh`     | recipient simulation: exact, plus-addressing, catch-all, alias domains, relay-all, unrelated domains           |
| `tests/test-install.sh`        | bootstrap, idempotency, preserved secrets, first-sync failure, checksum mismatch, local install, OS validation |
| `tests/test-update.sh`         | success, failure reporting, dry run, reboot detection, quiet mode, no destructive calls                        |
| `tests/test-diagnose.sh`       | AI prompt, redaction, address masking, read-only guarantees, report permissions                                |
| `tests/test-update-scripts.sh` | check, dry run, checksum/syntax rejection, self-update verification, rollback, safety                          |
| `tests/test-release.sh`        | archive layout, manifests, version consistency, invalid input                                                  |

Because no MTA is started, recipient acceptance is verified against a simulator
that implements the documented Postfix lookup order. Real-server acceptance is a
manual check, documented in
[`MANUAL-SETUP.md`](MANUAL-SETUP.md#verification).

### Formatting

Markdown and YAML are formatted with Bun's built-in formatter. It has no shell
parser, so it never touches the scripts and cannot change behaviour.

```bash
bun run format        # rewrite the files that need it
bun run format:check  # list them instead; exits 1 if any needs formatting
```

Configuration lives in `bunfig.toml` (80 columns, prose preserved, test
fixtures ignored) and `.editorconfig`. Bun is needed only for this step: there
are no dependencies, and `bun install` is never required.

Do not add an `fmt` script to `package.json`: `bun fmt` would run that script
instead of the formatter.

## Making a change

### Code rules

- Bash with `set -Eeuo pipefail`.
- One file per command, standalone, no shared library and no `source` between
  scripts: a script must keep working if copied alone to a server.
- No new runtime dependency beyond what the installer already installs
  (`postfix`, `jq`, `curl`, `ufw`, `logrotate`).
- Log through the existing `log`/`warn`/`err` helpers so timestamps and log
  files stay uniform.
- Never put a secret in `argv`, a log line or a report: the API key is passed to
  curl on stdin and redacted from diagnostics.
- Keep paths overridable through the existing `MXB_*` variables; that is what
  makes the scripts testable.
- `make lint` must be clean at ShellCheck warning level.

### Tests

- Run `make lint && make test` before pushing. CI runs the same commands.
- **Behaviour changes need a test.** Add or update a case in the relevant
  `tests/test-*.sh`; a bug fix should demonstrate the bug the tests could not
  catch before.
- Documentation-only pull requests are exempt from the test requirement.
- Never make a test depend on the network, a real MTA, or the local machine's
  state.

### Documentation

- `README.md` — what an operator reads: install, API key, health checks,
  troubleshooting.
- `DOCS.md` — lookup material: configuration keys, script flags, map and state
  tables, runtime paths. If you add a key, a flag or a table, it belongs here.
- `MANUAL-SETUP.md` — what the installer actually changes, by hand. If you add
  or rename a Postfix setting, a directory, a unit or a map, update this file.
- `MAINTAINER.md` — releases, CI internals, versioning.
- Do not duplicate a topic across files: each fact lives in one document and the
  others link to it. A repeated table is a review finding.

### Changelog

If your change is visible to operators, add one line under `[Unreleased]` in
[`CHANGELOG.md`](CHANGELOG.md) (`Added`, `Changed`, `Fixed`, `Removed`). The
maintainer may roll these into a release entry instead; a missing line never
blocks a pull request.

## Commit messages and pull request titles

Commit messages are yours to format, as long as the subject is a readable
imperative sentence. Pull request titles follow
[Conventional Commits](https://www.conventionalcommits.org/) and **CI enforces
them**:

```text
type(scope): subject
```

| Type       | Use for                                                         |
| ---------- | --------------------------------------------------------------- |
| `feat`     | a capability the project did not have                           |
| `fix`      | a defect in scripts, maps, units or docs that changes behaviour |
| `docs`     | documentation, comments, README/MANUAL-SETUP/MAINTAINER text    |
| `test`     | tests and test helpers only                                     |
| `refactor` | internal restructuring with no behaviour change                 |
| `perf`     | smaller or faster output, map or report generation              |
| `build`    | `Makefile`, `scripts/build-release.sh`, release archive layout  |
| `ci`       | `.github/workflows` and repository automation                   |
| `chore`    | maintenance that fits nowhere else                              |
| `revert`   | reverting an earlier change                                     |

Use a lowercase scope naming the script or area: `sync`, `install`, `diagnose`,
`update`, `update-scripts`, `release`, `docs`, `ci`.

```text
fix(sync): fall back to cache on HTTP 429
feat(diagnose): list deferral reasons by domain
docs(manual): add the postmap rebuild step
```

An exclamation mark (`feat(install)!: …`) marks a breaking change; explain the
migration in the pull request body.

This matters because the repository merges with the pull request title, and
release notes are generated from the merged history.

## Pull requests

A pull request is ready for review when all of the following are true:

- [ ] The title is a valid Conventional Commit (`type(scope): subject`).
- [ ] `make lint` and `make test` pass locally.
- [ ] Markdown/YAML changes pass `bun run format:check`.
- [ ] Behaviour changes include a test; documentation-only changes say so.
- [ ] Documentation is updated where the change is visible to operators.
- [ ] New or changed shell code keeps the Code rules above.
- [ ] One topic only; no unrelated reformatting, renames or drive-by edits.
- [ ] The description explains **why**, and how the change was verified.
- [ ] No secrets, real mail content, API keys or private hostnames are included.

Fill in [`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md);
the checklist is the same list.

### What CI runs

Every push and pull request is checked on Ubuntu 24.04 by `make lint`,
`make test`, a release build with checksum verification, and the pull request
title check. The exact steps and workflow files are listed in
[`MAINTAINER.md`](MAINTAINER.md#continuous-integration).

A red job means the pull request is not ready; a green job means it is ready for
review, not that it is merged.

### Review

- One maintainer reviews. Expect questions about scope before style.
- Small, focused pull requests are merged fastest.
- Force-pushing your branch is fine, but add a comment saying what changed
  after a review started.
- A reviewer may push a small fix directly to your branch; they will tell you.
- There is no review SLA. This is a small project maintained next to other work;
  a polite reminder after a week is welcome.

### What gets a pull request closed

- It needs a new dependency, daemon or configuration key that the scope rule
  rejects, and the issue was not agreed first.
- It fixes a symptom by disabling a safety property: relaxing TLS verification,
  widening `mynetworks`, accepting unknown recipients, or removing checksum
  verification.
- It rewrites large parts of a script without a behavioural reason, making the
  diff impossible to review.
- It adds a second way to do something the project already does.

## Security

Do not open a public issue for a vulnerability. Use the repository's
**Security → Report a vulnerability** tab so the report stays private. Include
the affected version (`VERSION`), the impact, minimal reproduction steps, and
what an attacker gains.

Never include a real Mailcow API key, a private key, or actual message content.
`mx-diagnose` already redacts them; use its output where possible.

The security properties the project will not trade away are listed in
[`README.md`](README.md#security-notes).

## License

The project is licensed under the **MIT License** ([`LICENSE`](LICENSE)). By
opening a pull request you confirm that you wrote the change or that it is
compatible with that license, and you agree it is distributed under the same
terms.

There is no CLA and no DCO sign-off requirement.

## Questions

If something here is unclear, open an issue with the `docs` prefix in the title
and say which paragraph confused you. A confusing contribution guide is a bug.
