# engineering — switchboard

How Dikta is built. Settled engineering rules and the CDE model that organises them.

## Contents

- [cde.md](cde.md) — Context-Driven Engineering: definition, operating rule, switchboard discipline.
- [conventions.md](conventions.md) — System-wide conventions: file/function caps, naming, comments, markdown, commits, Lua and shell specifics.
- [plans/](plans/) — Dated plan documents and frozen v0.1 spec; folder switchboard: [plans/README.md](plans/README.md).

## Principles driving the architecture

The load-bearing rules for this project:

- **A1 Context-Driven Engineering** — every meaningful folder has a README; missing context is a blocker.
- **A3 Refactoring is continuous** — 200-line soft cap, 300-line hard stop; no deferred cleanup.
- **A4 Smoke-testable paths get tests** — `dikta.sh transcribe` and any pure helper have smoke coverage; audio I/O and Hammerspoon Lua are manually verified.
- **A8 Spec → Plan → Implement** — no non-trivial implementation begins without a settled spec and a plan.
