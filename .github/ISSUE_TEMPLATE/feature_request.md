---
name: Feature request
about: Propose a change to the backup MX, after checking it fits the project scope
title: "feat(scope): "
labels: enhancement
assignees: ""
---

<!--
Read the scope rule in CONTRIBUTING.md first. This project stays lightweight,
simple, reliable and secure: anything that adds a service, a dependency or a
configuration key needs a very good operational reason.
-->

## The operational problem

<!-- Describe the situation on a real server. "When the primary is down for
three days and a mailbox is created, ..." beats "add an option to ...". -->

## Who is affected

<!-- Every deployment, a large Mailcow with many domains, IPv6-only hosts, etc. -->

## What you do today instead

<!-- The manual workaround, and why it is not good enough. -->

## Proposed behaviour

<!-- Optional. If you have a design, describe it; maintainers may choose another. -->

## Scope check

Does the proposal require any of the following with the default configuration?

- [ ] a new daemon or service beyond Postfix and systemd
- [ ] a new runtime dependency (database, Redis, agent, container runtime)
- [ ] a new configuration key in `/etc/mailcow-backup-mx/config`
- [ ] a second way to do something the project already does

If any box is ticked, explain why the project cannot solve the problem without
it.

## Alternatives considered

<!-- Including "do nothing" and "document a manual step". -->
