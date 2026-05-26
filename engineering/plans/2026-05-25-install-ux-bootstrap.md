# 2026-05-25 — Install UX rethink: install.sh becomes a true bootstrapper

Owner: thanpolas. Status: settled — all decisions locked; implementation ready to begin.

## Goal

Replace the current "validate-and-tell-the-user-what-to-do" install model with a single seamless flow: clone a tagged release, run `./install.sh`, and end up with a working voice-dictate — including any missing dependencies fetched on consent and any macOS permissions walked-through interactively. Delete [INSTALL.md][install-md] (in its own commit per the atomic-commits rule); the script's interactive output is the only install documentation going forward.

The forcing function for this work: if there is no INSTALL.md to fall back to, install.sh has to own the entire human walkthrough.

## Constraints and forces

- macOS-only. Apple Silicon assumed. Whatever we do can rely on `brew`, `defaults`, `open`, and the `hammerspoon://` URL scheme.
- The repo carries shell + Lua only. No Python, no Node — adding a runtime to host the installer is off-table. GitHub Actions in CI are fine (they don't add runtime to the project).
- Hammerspoon integration requires patching the user's `~/.hammerspoon/init.lua` and symlinking two Lua files. This is awkward for any distribution model that doesn't allow interactive post-install (rules out plain Homebrew formulas).
- The user may already have whisper.cpp models on disk under `~/whisper-models/` or wherever an existing `bin/config.local.sh` points. The bootstrapper must respect existing state, not duplicate downloads.
- The 200-line soft cap from [conventions.md][conventions-md] applies. Today's `install.sh` is 183 lines and only validates; a real bootstrapper will need to split.

## Decisions

**D1 — Distribution model: tagged GitHub releases, git-clone-then-checkout flow.**
Drops the "clone main and pray" model. Users land on the releases page or run a one-liner that clones + checks out the latest tag. `install.sh update` does `git fetch && git checkout <latest-tag>` plus a migration step (see D7). Hammerspoon Spoon migration stays a future plan.

**D2 — Auto-install posture: prompt per missing dep, then run it.**
For each missing piece (Homebrew itself, ffmpeg, whisper-cpp, Hammerspoon, model file), explain what it is and ask `y/N` with `y` as default. Most transparent; users see each step.

**D3 — Project-local artifact storage at `.local/`.**
install.sh creates `.local/` in the repo root (gitignored) and stores everything it fetches or generates inside it:

- `.local/models/` — Whisper checkpoint(s) downloaded by install.sh.
- `.local/state/version` — currently-installed release tag, written by install.sh on success and read by `update` + `migration.sh`.
- `.local/state/install.log` — append-only record of what install.sh did, for diagnostics.

Detect-first logic still applies: if the configured `MODEL_PATH` already points at a usable file (anywhere on disk), reuse it. Only download into `.local/models/` if nothing usable exists. `bin/config.local.sh` stays where it is — already gitignored and well-known to dictate.sh.

**D4 — Bootstrap Homebrew when missing, on consent.**
If `brew` isn't on PATH, the script explains what Homebrew is, names the official install URL (`https://brew.sh`), and asks `y/N` before invoking the upstream installer. Refusal exits cleanly with a one-line "install Homebrew manually and re-run me."

**D5 — Walk the user through macOS permissions.**
After install completes, the script opens the three relevant System Settings panes in sequence — Accessibility, Input Monitoring, Microphone — via `open "x-apple.systempreferences:com.apple.preference.security?..."` URLs. Between each, a prompt: "Press Enter when Hammerspoon is enabled under Accessibility (or 's' to skip)." This is the headline UX win — silently failing permissions are the #1 first-run friction; we own this end-to-end.

**D6 — Split install.sh into a modular `install/` directory.**
- `install.sh` — orchestrator at repo root. ≤120 lines. Argument dispatch (`install`, `update`), top-level prompt flow, calls into helpers.
- `install/deps.sh` — Homebrew detect + bootstrap; per-dep prompts; brew install dispatch.
- `install/model.sh` — model detect (scan known locations, read config.local.sh) + download into `.local/models/` on consent.
- `install/permissions.sh` — open System Settings panes in sequence with per-pane prompts.
- `install/hammerspoon.sh` — symlink the two Lua files, patch init.lua, trigger reload.
- `install/config.sh` — write `bin/config.local.sh` and `~/.hammerspoon/voice-dictate-config.lua` with prompted + derived values.
- `install/migration.sh` — single entry point for version-to-version migrations; see D7.
- `install/README.md` — folder switchboard per CDE.

Each helper sources a shared `install/lib.sh` for `ask()`, `log()`, `require_cmd()`, colored output. Caps every file at ≤200 lines.

**D7 — Implement `update` only; drop status / uninstall / repair from v0.x scope.**

`./install.sh update`:
1. Reads `.local/state/version` to learn the installed tag.
2. Queries GitHub Releases API (`gh release view --json tagName` or `curl https://api.github.com/repos/<owner>/<repo>/releases/latest`) for the latest tag.
3. If a newer tag exists, runs `git fetch --tags && git checkout <new-tag>`.
4. Invokes `install/migration.sh <from-tag> <to-tag>` to run any version-bridging steps (config-file schema upgrades, file moves, deprecation warnings).
5. Re-runs the regular install path so any new deps / config keys land.
6. Writes the new tag to `.local/state/version`.

`migration.sh` is the single touchpoint for "what changed between version X and Y, and how do we move the user there." It dispatches per-version internally (e.g., `migrate_0_1_to_0_2()`).

**D8 — Release automation via `release-please` GitHub Action.**

Add `.github/workflows/release-please.yml`. It reads our existing Conventional Commits, computes the next semver bump (`feat` → minor, `fix` → patch, `BREAKING CHANGE:` → major), opens a release PR with a `CHANGELOG.md` update and version bump, and — when the release PR merges — creates a GitHub Release + git tag automatically. No Node or Python added to the project; the action runs in CI.

Tradeoff: PR-gated rather than instantaneous. That's a feature, not a bug — it forces a deliberate "is this releasable?" review step. If we ever want instant tagging, a `cocogitto` or `gh release create` script is a one-day swap.

**D9 — Ship as atomic commits, not as one big bundle.**

Per the [atomic-commits rule][conventions-md], each logical unit is its own commit. The install.sh rewrite, the INSTALL.md deletion, the README trim, and the release-please workflow are *four* commits, sequenced so each one leaves the repo in a coherent state:

1. `feat: add install/ helpers and .local/ runtime state` — new bootstrapper, no removals.
2. `refactor: rewire install.sh as orchestrator over install/ helpers` — old install.sh becomes the dispatcher.
3. `feat: install.sh update + migration.sh skeleton` — adds the update path.
4. `ci: add release-please workflow for automated tagged releases` — release automation lands separately.
5. `docs: delete INSTALL.md and trim README install section` — only ships once install.sh's interactive output covers everything INSTALL.md did.

Order matters: never delete INSTALL.md until commits 1–3 actually replace its content; never add release-please until there's something worth releasing.

## Sequence of work

1. Scaffold `install/` directory with empty helper files + `install/README.md` (CDE first).
2. Implement `install/lib.sh` (`ask`, `log`, `require_cmd`, color helpers).
3. Implement `install/deps.sh` — brew detect + bootstrap + per-dep prompts.
4. Implement `install/model.sh` — detect + download into `.local/models/`.
5. Implement `install/config.sh` — same writes today's install.sh does, extracted.
6. Implement `install/hammerspoon.sh` — symlink + init.lua patch + reload, extracted.
7. Implement `install/permissions.sh` — System Settings pane walk-through.
8. Rewrite `install.sh` as a thin orchestrator dispatching `install` (default) and `update`.
9. Implement `install/migration.sh` skeleton — version detection + per-version dispatcher with no migrations yet (placeholder for future use).
10. Add `.github/workflows/release-please.yml`.
11. Manual e2e on a clean macOS user account (or VM snapshot).
12. Delete INSTALL.md; trim README's install section to "clone the latest release tag + `./install.sh`" + a one-screenshot transcript of what the user will see.
13. Update INVENTORY.md (drop INSTALL.md entry; add `install/` folder entry) and [bin/README.md][bin-readme] § Configurable values (model-path narrative changes).

## Cross-doc effects

- `INVENTORY.md` — drop INSTALL.md entry; add `install/` folder entry with switchboard link.
- `README.md` — replace install section with a 5-line "clone latest release tag, run install.sh" plus a screenshot/transcript.
- [v0.1 spec][v01-spec] — § Dependencies and § Configuration surface carry the pre-bootstrapper assumption that the installer only validates. The spec stays frozen as historical; this plan is the source of truth for the install contract going forward.
- [bin/README.md][bin-readme] — model-path narrative shifts: "detect first, fall back to `.local/models/`."
- `hammerspoon/README.md` — no change expected.

## Risks

- **Bootstrap-from-zero is hard to test.** The interesting case is a machine with none of brew, ffmpeg, whisper-cpp, Hammerspoon installed. Cleanest test surface is a fresh macOS user account or a VM snapshot — not the dev box. Until tested there, the "seamless" claim is unverified.
- **Model download is 547 MB.** A failed download mid-stream needs a resumable retry (`curl -C -`) or the user re-runs the whole installer. Pick resumable.
- **Permissions are out-of-process.** Even with the System Settings panes opened, the user might dismiss them and forget. The Lua module should keep its existing `hs.notify` toast on first-use permission failure as a backstop — separate from this plan, but worth noting.
- **Release-please learning curve.** First few releases may produce unexpected version bumps if commits are mis-typed. Mitigation: review the auto-opened release PR before merging.
- **Migration script grows unbounded.** Every new version potentially adds a `migrate_X_to_Y()` function. Soft-cap at ~150 lines; if it grows past, split into per-version files under `install/migrations/`.

[install-md]: ../../INSTALL.md
[conventions-md]: ../conventions.md
[v01-spec]: 2026-05-20-v0.1-spec.md
[bin-readme]: ../../bin/README.md
