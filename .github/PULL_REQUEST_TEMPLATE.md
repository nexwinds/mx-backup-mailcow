<!--
Title: use Conventional Commits, e.g. "fix(sync): fall back to cache on HTTP 429".
CI rejects titles that do not match. See CONTRIBUTING.md for the type list.
-->

## What and why

<!-- The problem, the change, and why this is the smallest correct fix. -->

## How it was verified

```bash
make lint
make test
```

<!-- Paste the relevant output. For runtime changes, describe the lab check you
performed and on which host (never paste real mail content). -->

## Checklist

- [ ] Title is a valid Conventional Commit (`type(scope): subject`)
- [ ] `make lint` and `make test` pass locally
- [ ] Markdown/YAML changes pass `bun run format:check`
- [ ] Behaviour changes include a test; documentation-only changes say so here
- [ ] Operator-visible documentation updated (`README.md`, `OPERATIONS.md`,
      `TROUBLESHOOTING.md`, `DOCS.md`)
- [ ] One topic only, no unrelated reformatting or drive-by edits
- [ ] No secrets, API keys, private keys, real addresses or message content

## Related issues

Closes #
