# voice-dictate — Conventions

Settled engineering rules for this repo. Nothing here is per-task negotiable. If a rule needs to change, change it here in the same session as the implementation that motivates the change.

## Spec ground rules

- Scope and architecture decisions live in dated plan files under [`engineering/plans/`][plans-readme]. One body of work per plan; folder READMEs own folder context.
- A plan is **settled** when it has no implicit open questions that would materially change the implementation. Explicitly deferred decisions are fine — flag them in the plan itself.
- Plans are immutable once shipped — they are the durable record of what was decided when. Subsequent scope changes open a new dated plan that names the prior plan it extends or supersedes.
- The process is **Spec → Plan → Implement**, in that order. No stage is skipped for non-trivial work. In practice the "spec" lives inside the dated plan that owns the work.

## File and function size

Source files (`*.sh`, `*.lua`):

- **Soft cap 200 lines** — re-evaluate; ask if the file is doing too many things.
- **Hard stop 300 lines** — requires an explicit top-of-file carve-out comment justifying it.

Split triggers — extract into a new file when: a new logical concern is introduced, private helpers exceed the exported surface in volume, or a single function would push the file over the soft cap.

Function bodies:

- **Function body cap: 45 lines** (excluding the docblock). Long bodies extract to named helpers.
- **Function arguments: ≤4.** Use a table / options structure for 5 or more.
- **Loop body cap: 8–10 lines.** Longer bodies extract to a named function.
- **Conditionals stay thin — no loops inside an `if` / `else` body.** If a branch needs to iterate, extract the iterating block into a named helper and call it from the branch.
- **Nesting depth: 3 levels max.** Use early returns or guard clauses.

## Within-file function ordering — top-down

1. File header comment (`# @fileoverview` for shell, `--- @fileoverview` for Lua).
2. Runtime setup — shell `set -euo pipefail` and `export PATH=…`; Lua `local M = {}`.
3. Module-level constants and state.
4. Public API / entry points.
5. Private helpers, ordered by call depth (callers above callees).
6. Lifecycle (`M.start` / `M.stop`, `main "$@"`) at the bottom.

If a function has a name, its position in the file encodes its importance. Top = most important; bottom = lowest-level internal helper.

## Naming

- Intention-revealing names: `transcribeAndPaste()` not `process()`, `MODEL_PATH` not `M`.
- Functions are verbs (`startRecording`, `transcribe`, `verifyDeps`); the module table is a noun (`M`).
- Boolean variables and functions start with `is`, `has`, `should`, `can` — `isRecording`, `hasModel`, `shouldRetry`.
- Avoid generic names — `data`, `info`, `item`, `result`, `manager`, `handler` — outside tiny scopes (≤10 lines).
- No string literals scattered through code to represent states. Extract to module-scoped constants.

## Comments and docblocks

- **Every source file opens with an `@fileoverview` block.** Shell uses `# @fileoverview …`; Lua uses `--- @fileoverview …`. One short paragraph: what the module does, plus the public API surface if it has one.
- **Every named function gets a docblock.** Exported or not.
  - Shell: leading `#` comment lines above the `function` keyword. One sentence describing what the function does, one sentence per non-obvious argument.
  - Lua: LDoc style — `--- summary` line, then `--- @param name type description` per argument, then `--- @return type description` when there is one.
- **Every module-level constant carries a single-line description above it.** Shell: `# description` above `readonly NAME=…`. Lua: `--- description` above `local NAME = …`. State what the value represents and why, in one line.
- **Inline comments only when the WHY is non-obvious** — a hidden constraint, a surprising workaround, a subtle invariant. Never restate what the code already says.
- One-line max for inline comments. Multi-paragraph commentary belongs in the file header or in a README, never inline.

## Markdown — reference-style links

**All links in markdown documents use reference-style, not inline.** Every link is `[text][label]` in the body and every URL or path is collected at the bottom of the document under `[label]: target`.

- **Why:** prose stays readable, URLs are de-duplicated, broken links are trivial to spot in one block at the bottom.
- **Format:** `[visible text][label]` in the body; `[label]: path/or/url` in the link-definition block at the very bottom (after the final content section, separated by a blank line).
- **Labels** are lowercase kebab-case, descriptive (`[engineering/cde.md][cde-md]` not `[…][1]`). Numeric labels are forbidden.
- **One definition per label.** Reuse a label across body references when they point to the same target.
- **External URLs follow the same rule** — no raw `https://…` inlined in prose.

### Exempt — switchboards only

Switchboards (root `INVENTORY.md`, area indexes like `engineering/README.md`, any folder README whose body is a list of links to siblings) keep inline links. The switchboard rule mandates the one-line form `- [Title](path) — purpose hook.` — reference-style would split each entry across two locations. See [`cde.md`][cde-md] under "Switchboard discipline".

A document is a switchboard only if its body is **predominantly** a list of links to other docs. A leaf README, plan, or operational doc is not a switchboard, even if it contains a link table or two.

### What stays backticked, not linked

- Code identifiers (function names, variable names, constant names).
- Shell commands, environment variables, keycodes.
- File paths inside code blocks (the surrounding block disambiguates).

## Markdown — no horizontal rules

**Do not use `---` horizontal rules.** Section dividers are `##` headers only. `---` HRs cause rendering glitches in VS Code's markdown preview. This applies to all new docs and to existing docs the moment they are touched for substantive reasons.

## Lua specifics

- One module per file. Module table is `local M = {}`; exported functions are `function M.name() … end`; private helpers are `local function name() … end`.
- All state at module scope is `local` — no globals. Constants above state; state above helpers.
- `M.start()` is idempotent — it calls `M.stop()` first so `hs.reload()` is always safe. `M.stop()` is safe to call repeatedly. No accumulation of taps, hotkeys, or menubar items across reloads.
- LDoc-style docblocks: `--- summary`, `--- @param name type description`, `--- @return type description`.
- Filter Hammerspoon eventtaps narrowly — match the exact keycode, return `false` to never swallow events when the tap is observational.
- Path constants resolve via `os.getenv("HOME") .. "/…"`, not hardcoded absolute paths.

## Shell specifics

- Shebang: `#!/usr/bin/env bash`. Not `sh` — voice-dictate uses bashisms (`[[ ]]`, `${var:-default}`, arrays).
- **`set -euo pipefail` is mandatory.** No `set +e` anywhere.
- Constants declared at the top with the environment-variable override pattern: `: "${VAR:=default}"; readonly VAR`. Single-line `# description` above each.
- Functions declared with the `function` keyword for searchability: `function name() { … }`.
- All variable references quoted: `"${VAR}"` not `$VAR`. Especially file paths and arguments.
- One subcommand per function. The `main` function dispatches via `case` on `"${1:-}"`.
- Spawn external processes via `exec` when the parent should be replaceable — e.g. `record` exec-s ffmpeg so Hammerspoon can `terminate` it directly without an intermediate bash PID.
- Trap signals deliberately. ffmpeg's `SIGINT` / `SIGTERM` flush-on-exit behaviour is load-bearing in `record` — document the dependency where it's relied on.
- Normalise `PATH` at the top of scripts spawned by Hammerspoon — `hs.task` inherits a minimal environment that doesn't include `/opt/homebrew/bin`.

## Conventional Commits

All commits follow the [Conventional Commits][conventional-commits] format:

```
<type>: <description>

<optional body>
```

| Type       | When to use                                             |
|------------|---------------------------------------------------------|
| `feat`     | New feature or capability                               |
| `fix`      | Bug fix                                                 |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `docs`     | Documentation only                                      |
| `chore`    | Tooling, install scripts, hooks                         |

Rules:

- Imperative mood in the description ("add", "fix", "change" — not "added", "fixes", "changed").
- First line under **72 characters**.
- Description explains **why**, not just what.
- One logical change per commit — do not bundle unrelated changes.

## No commits without explicit instruction

Never stage, commit, or push without being explicitly told to. The user controls git history.

## Bug fixes — failing test first (where possible)

The testable surface in voice-dictate is `dictate.sh transcribe` plus any future pure helper. For bugs on that surface:

1. Add a `bin/test-*.sh` reproducer (or extend `dictate.sh smoke`) that demonstrates the bug.
2. Confirm it fails against the current code.
3. Implement the minimal fix.
4. Confirm it passes.

For bugs on the non-testable surface — audio I/O, Hammerspoon Lua, hotkey handlers — a manual repro checklist replaces the failing test. Document the steps in the commit body.

## Duplication and reuse

- If the same logic appears in 3+ places, extract it. Two similar-looking blocks with different purposes are not duplicates.
- Three similar lines is better than a premature abstraction.

[plans-readme]: plans/README.md
[cde-md]: cde.md
[conventional-commits]: https://www.conventionalcommits.org/
