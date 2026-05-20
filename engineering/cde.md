# Context-Driven Engineering (CDE)

An engineering model where every meaningful area of the codebase carries its own local context in the form of living README files, treated as part of the architecture — not optional documentation, not afterthoughts.

## Core idea

Context is **distributed, local, and hierarchical** — not centralised in one giant document:

- **Root context** — [`CLAUDE.md`][claude-md] and [`INVENTORY.md`][inventory-md]: overall architecture, hard rules, repository map.
- **Folder context** — each meaningful folder has a README describing what it owns, its dependencies, constraints, and how to change it safely. Today: [`bin/README.md`][bin-readme] and [`hammerspoon/README.md`][hammerspoon-readme].

The LLM (or human) uses these READMEs as a **switchboard**: start at the root, then follow the local READMEs for the area being worked on.

## Purpose

- System behaviour is easier to understand — context lives next to the code.
- Hidden assumptions are reduced — constraints are written where they apply.
- LLMs load only the context relevant to their scope instead of re-deriving it from the whole tree.
- Each folder's README is the **authoritative source of truth** for that folder's responsibilities and boundaries.

## Operating rule

**Missing or unclear context is a blocker, not a prompt to guess.**

- New meaningful folders get a README in the same change.
- Behaviour changes update the README in the same change.
- Stale READMEs are fixed as part of current work — never deferred.

## Switchboard discipline

A **switchboard** is any document whose body is a directory of links to other docs — it points to where context lives, it does not host that context. The repository has switchboards at multiple levels:

- **Root** — [`INVENTORY.md`][inventory-md].
- **Folder switchboards** — any folder README whose body is mostly a list of siblings (e.g. [`engineering/README.md`][engineering-readme]).

A switchboard entry is a single line that names the linked folder or file and gives a one-sentence purpose hook. Anything more belongs in the leaf README that owns the area.

A **leaf README** — one that owns a folder's content rather than indexing siblings — is exempt from this rule and is where the actual context lives. Both [`bin/README.md`][bin-readme] and [`hammerspoon/README.md`][hammerspoon-readme] are leaf READMEs.

### Hard rules — switchboard entries

- **One line per entry.** Hard cap: **180 characters**, link included.
- **Format:** `- [Title](path) — one-sentence purpose hook.`
- **The hook says what the area is for**, not what's inside, what changed recently, or how it's wired.
- **Applies at every nesting level** — root, folder switchboard. The rule does not relax as you descend.

### Forbidden in switchboard entries

- Function, command, or constant names.
- File paths or shell commands.
- Implementation-state language: "currently …", "recently added …", "now also …".
- Lists of sub-files or sub-modules.
- Decision rationale or design notes — link to the relevant doc instead.

### Required in switchboard entries

- A `[Title](path)` link to the folder or file.
- A single sentence describing what the area is for, written so a reader can tell whether to open it.

### Where the detail lives

- **Leaf folder READMEs** — own the content for their area: responsibilities, contracts, constants, constraints, sub-file lists.
- **[`SPEC.md`][spec-md] and [`PLAN.md`][plan-md]** — own cross-cutting scope, architecture, sequencing.
- **Switchboards (any level)** — only point; never describe. If you find yourself wanting to add a second sentence, the content belongs one click down.

### Audit cadence

- An entry over 180 chars, or containing any forbidden item above, is a CDE violation.
- Fix violations in the same change that next touches the area — never defer indefinitely.
- At session start (`/start`), a quick scan for outsized entries is part of the CDE compliance check.

### Why this matters

Switchboard bloat is silent context leakage. Every session loads the root inventory; every char in a switchboard entry is a token spent on something that should live one click away in a local README. The bigger the switchboard, the less attention budget remains for the actual work — and the more places need updating when implementation shifts. Discipline here is what makes CDE pay back.

[claude-md]: ../CLAUDE.md
[inventory-md]: ../INVENTORY.md
[engineering-readme]: README.md
[bin-readme]: ../bin/README.md
[hammerspoon-readme]: ../hammerspoon/README.md
[spec-md]: ../SPEC.md
[plan-md]: ../PLAN.md
