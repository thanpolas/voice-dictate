# Dikta — engineering entry point

This file is loaded at every session start. It is the authoritative index for engineering rules; depth lives in [`engineering/`][engineering]. Read it first, then orient from [`INVENTORY.md`][inventory-md].

## Context-Driven Engineering (CDE)

Every meaningful area of the codebase carries its own local context in the form of living README files, treated as part of the architecture — not optional documentation, not afterthoughts.

Context is **distributed, local, and hierarchical**:

- **Root context** — this file and [`INVENTORY.md`][inventory-md]: overall architecture, hard rules, repository map.
- **Folder context** — each meaningful folder has a README describing what it owns, its constraints, and how to change it safely. Today: [`bin/README.md`][bin-readme] and [`hammerspoon/README.md`][hammerspoon-readme].

Use these READMEs as a **switchboard**: start at the root, follow local READMEs for the area being worked on. Load only the context relevant to scope.

**Operating rule:** missing or unclear context is a blocker, not a prompt to guess. New folders get a README in the same change; behaviour changes update the README in the same change; stale READMEs are fixed as part of current work — never deferred.

Full definition: [`engineering/cde.md`][cde-md].

## Master switchboard

[`INVENTORY.md`][inventory-md] is the root map of every folder, file, and document in this repository. Navigate from it.

Switchboards exist at every level — root `INVENTORY.md` and any folder README whose body is a list of links to siblings (e.g. [`engineering/README.md`][engineering-readme]). All follow the same rule: one line per entry, ≤180 chars, format `- [Title](path) — purpose hook.` Implementation detail belongs in the leaf README that owns the area, not in any switchboard upstream of it. Full rules: [`engineering/cde.md`][cde-md] under "Switchboard discipline".

## Hard engineering principles

| Principle | Rule | Detail |
|-----------|------|--------|
| **A1 — CDE** | Every meaningful folder has a README. Missing context is a blocker. | [`engineering/cde.md`][cde-md] |
| **A2 — No inline literal values** | Paths, URLs, ports, settings keys, state labels — module-level constants or config values, never inline at call sites. Format strings and one-shot error text are mechanics, not values. | [`engineering/conventions.md`][conventions-md] |
| **A3 — Refactor continuously** | 200-line soft cap, 300-line hard stop for source files. No deferred cleanup. | [`engineering/conventions.md`][conventions-md] |
| **A4 — Smoke-test pure paths** | `dikta.sh transcribe` and any pure helper get smoke coverage. Audio I/O and Hammerspoon Lua are manually verified. | [`engineering/conventions.md`][conventions-md] |
| **A8 — Spec → Plan → Implement** | No non-trivial implementation begins without a settled spec and a plan. | [`engineering/conventions.md`][conventions-md] |

## Dated plans

Scope, architecture decisions, and implementation order all live in dated plan files under [`engineering/plans/`][plans-readme]. Each plan is `YYYY-MM-DD-slug.md`, owns one body of work, and stays in the tree as the durable record once the work ships. The locked v0.1 spec is frozen there as a historical reference; subsequent scope changes are new dated plans rather than edits to old ones.

Spec drift — where code and the most recent applicable plan diverge — is a critical failure in CDE. It breaks every future session. When implementation deviates from the plan that authorised it, open a new dated plan in the same change.

## Comments and docblocks

- Every source file opens with `@fileoverview` (`# @fileoverview` in shell, `--- @fileoverview` in Lua).
- Every named function gets a docblock — shell uses leading `#` lines; Lua uses LDoc-style `---` with `@param` / `@return`.
- Every module-level constant carries a single-line description above it.
- Inline comments only when the WHY is non-obvious. Never restate what the code does.

Full rules: [`engineering/conventions.md`][conventions-md] § Comments and docblocks.

## Markdown

- **Reference-style links** in all docs (`[text][label]` + link block at the bottom). Switchboards are the only exception — they use the one-line `[Title](path)` inline form.
- **No `---` horizontal rules.** Section dividers are `##` headers only — `---` rules break VS Code's markdown preview.

## Scratch paths

- **All transient artefacts go in the repo-local `tmp/` directory, never `/tmp`.** This applies to PID files, log files, in-progress WAVs, snapshots, test fixtures, fu-log — anything ephemeral. `tmp/` is gitignored and survives only as long as the repo checkout, which is exactly the right scope. System `/tmp` is shared with other tooling and routinely scavenged by the OS; debugging is harder when two unrelated runs collide and impossible after a reboot wipes the evidence.
- **Shell scripts derive `tmp/` from `SCRIPT_DIR`** (e.g. `readonly TMP_DIR="${SCRIPT_DIR}/../tmp"`) and `mkdir -p` on entry — never hardcode an absolute path. Lua modules derive it from the script-path config (`cfg.stream_sh` etc.) by stripping `/bin/<file>`.
- **Exception:** none in this repo. If you find yourself reaching for `/tmp`, you are wrong.

## Naming

- Intention-revealing: `transcribeAndPaste`, `MODEL_PATH`. Not `process`, not `m`.
- Functions are verbs; the module table is a noun.
- Booleans start with `is`, `has`, `should`, `can`.
- Avoid generic names — `data`, `info`, `item`, `result`, `manager`, `handler` — outside tiny scopes.

## Commits

[Conventional Commits][conventional-commits] format. Imperative mood, first line ≤72 chars, body explains why.

**No commits without explicit instruction.** Never stage, commit, or push without being told to. The user controls git history.

[engineering]: engineering/
[engineering-readme]: engineering/README.md
[inventory-md]: INVENTORY.md
[cde-md]: engineering/cde.md
[conventions-md]: engineering/conventions.md
[bin-readme]: bin/README.md
[hammerspoon-readme]: hammerspoon/README.md
[plans-readme]: engineering/plans/README.md
[conventional-commits]: https://www.conventionalcommits.org/
