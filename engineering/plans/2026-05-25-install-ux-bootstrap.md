# 2026-05-25 — Install UX rethink: install.sh becomes a true bootstrapper

Owner: thanpolas. Status: drafting — recommendations settled where marked, open questions below.

## Goal

Replace the current "validate-and-tell-the-user-what-to-do" install model with a single seamless flow: clone the repo, run `./install.sh`, and end up with a working voice-dictate — including any missing dependencies fetched on consent. Delete [INSTALL.md][install-md] in the same change; the script's interactive output is the only install documentation.

The forcing function for this work: if there is no INSTALL.md to fall back to, install.sh has to own the entire human walkthrough.

## Constraints and forces

- macOS-only. Apple Silicon assumed. Whatever we do can rely on `brew`, `defaults`, `open`, and the `hammerspoon://` URL scheme.
- The repo carries shell + Lua only. No Python, no Node — adding a runtime to host the installer is off-table.
- Hammerspoon integration requires patching the user's `~/.hammerspoon/init.lua` and symlinking two Lua files. This is awkward for any distribution model that doesn't allow interactive post-install (rules out plain Homebrew formulas).
- The user already has whisper.cpp models elsewhere on this machine (`~/tiktok/whisper-models/`, `~/whisper-models/`). The bootstrapper must respect existing state, not duplicate downloads.
- The 200-line soft cap from [conventions.md][conventions-md] applies. Today's `install.sh` is 183 lines and only validates; a real bootstrapper will need to split.

## Decisions (settled with user)

**D1 — Distribution model: clone + `./install.sh` now, Hammerspoon Spoon in v0.2.**
Lowest-risk path that solves the actual UX problem. Spoon migration is a separate plan once the bootstrapper UX is settled; it changes how users *install*, not how the tool *works*, so it can ride on top.

**D2 — Auto-install posture: prompt per missing dep, then run it.**
For each missing piece (Homebrew itself, ffmpeg, whisper-cpp, Hammerspoon, model file), explain what it is and ask `y/N` with `y` as default. Most transparent; users see each step; the script is auditable while running. The cost is more prompts, accepted in exchange for trust.

## Open questions

These are the decisions that gate implementation. Resolve before writing code.

### Q1 — Where does the model live when install.sh has to download it?

Three candidates:

- `~/whisper-models/` — current README default. Visible, co-located with any other whisper.cpp checkpoints the user keeps.
- `~/Library/Application Support/voice-dictate/models/` — Mac-native, hidden, fully owned by us — clean uninstall by removing one folder.
- **Detect first, fall back.** Scan known whisper-model locations (`~/whisper-models`, `~/tiktok/whisper-models`, the path in any existing `bin/config.local.sh`); reuse if a usable model exists; only download to `~/whisper-models/` if nothing is found.

Recommendation: **detect-first, fall back to `~/whisper-models/`**. Reusing the user's existing state is the highest-respect default, and the fallback is the same path the README already documents — no new directory to explain.

### Q2 — Install Homebrew itself if missing?

If the user has none of `brew`, `ffmpeg`, `whisper-cli`, `Hammerspoon.app`, the script has to bootstrap Homebrew first. That means running the official `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` under a consent prompt.

Options:
- **Offer it.** Same consent pattern as for any other dep; user can say no and bail out.
- **Refuse and exit.** Print a one-line "install Homebrew first: https://brew.sh" and stop. Avoids responsibility for nested installers.

Recommendation: **offer it.** Consistent with the per-dep-prompt posture. The Homebrew installer itself is interactive and prints what it will do; we're just orchestrating consent.

### Q3 — Walk the user through macOS permissions, or leave them to discover?

Today the permission flow is documented in INSTALL.md and discovered on first hotkey use. After we delete INSTALL.md, the user has nothing.

Options:
- **Print + open System Settings panes.** After the install finishes, the script opens the Accessibility / Input Monitoring / Microphone panes in order via `open "x-apple.systempreferences:..."` URLs, with a prompt between each ("press Enter when you've added Hammerspoon under Accessibility"). High-touch, high-trust.
- **Print only.** Echo a short checklist with the exact pane to open in each case; let the user click through it.
- **Lazy / on-demand.** Have the Lua module detect permission failures at first use and toast a notification with a "Open System Settings" button via `hs.urlevent`. Defers complexity to runtime.

Recommendation: **print + open System Settings panes, sequentially**, with a clear "skip" option per pane. The deletion of INSTALL.md is the whole point — permissions are the single highest-friction part of first-run UX and absolutely cannot fall off.

### Q4 — How does install.sh stay under the size cap after taking on this much?

Today: 183 lines doing validation + config write + symlink + init.lua patch.
Tomorrow: dep detect + brew bootstrap + per-dep install + model detect + model download + permission walkthrough + config + symlink + patch + reload + status output. Will exceed 300 lines.

Options:
- **Split into an `install/` directory** with `install.sh` as the orchestrator and `install/deps.sh`, `install/model.sh`, `install/permissions.sh`, `install/hammerspoon.sh` as siblings. Each one ≤200 lines. New folder gets a README per CDE.
- **Multiple installer entry points** — `install.sh deps`, `install.sh model`, `install.sh permissions`, with a default `install.sh` that runs all of them. Single file, subcommand dispatch like `dictate.sh`. Caps the file at 300 lines tops, may still need a sibling helper file or two.
- **Sourced helper file** — `install.sh` stays the only entry point but sources `install-helpers.sh` for the heavy lifting. Two files, no folder.

Recommendation: **split into an `install/` directory** with one helper per concern. CDE-friendly (folder README owns the bootstrap contract), each helper is independently shellcheck-able, and the orchestrator stays small enough to read end-to-end.

### Q5 — Subcommands: status, repair, update, uninstall?

Today: `./install.sh` does everything; there is no `./install.sh uninstall` (INSTALL.md tells users to `rm` the symlinks manually) and no `./install.sh status` (users have to introspect by hand).

Options:
- **Status quo.** Single entry point. Re-running is the only operation.
- **Add `status` and `uninstall`.** `status` reports what's installed and where. `uninstall` reverses every mutation install.sh made (symlinks, init.lua line, config files, **not** brew packages or model).
- **Add `status`, `uninstall`, and `update`.** `update` does `git pull` + reinstall, future-proofing for users who don't `cd` in to upgrade.

Recommendation: **`status` and `uninstall` are worth adding** (low complexity, large UX win). `update` is a thinner win — `git pull && ./install.sh` already does it; revisit when the user base is non-zero.

### Q6 — Should INSTALL.md's deletion ship in the same commit as the bootstrapper rewrite?

Yes. They are tightly coupled — deleting INSTALL.md first leaves the README pointing at a missing file; rewriting install.sh first leaves a stale INSTALL.md contradicting it. Single commit, single coherent change. (Noted here because the rule is "delete docs in the same change that obsoletes them" — easy to forget mid-implementation.)

## Sequence of work (after Q1–Q5 resolved)

1. Lock the new install.sh contract inside this plan: subcommands, dep matrix, prompts, side-effects. This plan supersedes the [v0.1 spec][v01-spec]'s Configuration surface and Dependencies sections — those carry the pre-bootstrapper assumption that the installer only validates.
2. Restructure `install.sh` into `install/` orchestrator + helpers (per Q4). Add `install/README.md`.
3. Implement dep detection + per-dep install prompts.
4. Implement model detect-and-download (per Q1).
5. Implement permission walkthrough (per Q3).
6. Add `status` and `uninstall` (per Q5).
7. Delete INSTALL.md. Trim README.md's install section to "clone + `./install.sh`" + a screenshot/transcript of what the user will see.
8. Update INVENTORY.md and any leaf README cross-references (notably [bin/README.md][bin-readme] § Configurable values, where the model-path narrative changes if Q1 lands "detect first").

## Cross-doc effects

- `INVENTORY.md` — drop INSTALL.md entry, add `install/` folder entry when it lands.
- `README.md` — replace "Detailed walkthrough… INSTALL.md" link with one paragraph or remove entirely.
- [v0.1 spec][v01-spec] — § Dependencies says "install script does not install these — it validates them." That assumption inverts; the spec stays frozen as historical, this plan is now the source of truth for the install contract.
- [bin/README.md][bin-readme] — references to install.sh's behaviour are still accurate, but the model-path narrative changes if Q1 lands "detect first."
- `hammerspoon/README.md` — no change expected.

## Risks

- **Bootstrap-from-zero is hard to test.** The interesting case is a machine with none of brew, ffmpeg, whisper-cpp, Hammerspoon installed. Cleanest test surface is a fresh macOS user account or a VM snapshot — not the dev box. Until tested there, the "seamless" claim is unverified.
- **Model download is 547 MB.** A failed download mid-stream needs a resumable retry (`curl -C -`) or the user re-runs the whole installer. Pick one.
- **Permissions are out-of-process.** Even with the System Settings panes opened, the user might dismiss them and forget. Q3's lazy/on-demand option might still be needed as a backstop regardless of which Q3 path we pick.

[install-md]: ../../INSTALL.md
[conventions-md]: ../conventions.md
[v01-spec]: 2026-05-20-v0.1-spec.md
[bin-readme]: ../../bin/README.md
