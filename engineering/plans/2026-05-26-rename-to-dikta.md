# 2026-05-26 — Rename voice-dictate to Dikta

Owner: thanpolas. Status: draft — name **locked** (Dikta); rename sequenced and forced codebase-wide. The repo/folder + GitHub-slug rename is the one deferred piece, cut over on the user's go (see [D4][external-anchor]); availability is due-diligence, not a gate (see [D7][availability-anchor]).

This plan extends the [branding-identity plan][branding-plan], which analysed the options and recorded the user's choice of **Dikta** (2026-05-26). That plan decided *the name and identity direction*; this plan owns *the mechanical rename* across the codebase. It also consumes the rename blast-radius enumeration from that plan's "Cross-doc and rename blast radius" section rather than restating it.

## Goal

Rename the product from `voice-dictate` to **Dikta** everywhere it is load-bearing — module filenames and their `require()` calls, the shell entry point, config filenames and keys, the NSUserDefaults key, temp-file prefixes, user-visible strings, and all docs — without breaking a working install and without silently orphaning an existing user's saved microphone. Ship it as a sequence of atomic commits, each leaving the repo in a coherent state.

The product is **not yet published**, so the external surface (GitHub slug, any future Homebrew tap, domain) is low-cost to change and has no downstream consumers to break. The internal surface is where the care goes.

## Constraints and forces

- **A half-renamed repo is broken.** The Lua `require()` graph, the symlink names, and the `dictate_sh` config path all have to move together or Hammerspoon fails to load the module. Atomic-commit sequencing ([conventions.md][conventions-md] § Atomic commits) means each commit must still load and run — so renames that span the require graph happen *within a single commit*, not spread across several.
- **The saved mic is the one piece of user state that survives the repo.** The mic choice lives in NSUserDefaults under `voice-dictate.audioDevice` ([v0.1 spec][v01-spec] § Mic selection), outside the repo. Renaming the key without migrating it silently resets every existing user's microphone to the `:0` fallback — the single most user-affecting line in the [rename blast radius][rename-radius]. A read-fallback or a migration step is mandatory.
- **The install-UX bootstrap work is mid-flight.** The [install plan][install-plan] is actively reshaping `install/` (config generation, `migration.sh`, `.local/state`). This rename touches the same files (`install/config.sh` writes the config filename and keys; `install/hammerspoon.sh` creates the symlinks; `install/migration.sh` is the natural home for the NSUserDefaults migration). Coordinate ordering so the two efforts do not collide — ideally land the rename *after* the bootstrap helpers stabilise, or carve the touched lines explicitly.
- **Frozen docs stay frozen.** The [v0.1 spec][v01-spec] and the older implementation plan are historical records. Per [conventions.md][conventions-md] § Spec ground rules, shipped plans are immutable — the rename does *not* rewrite their bodies. Where the old name appears in them, it stands as the name at that date.
- **The markdown rules from [conventions.md][conventions-md] apply to this document:** reference-style links, no `---` horizontal rules.

## Decisions

**D1 — Adopt "Dikta" as the product name.** Recorded in the [branding-identity plan][branding-plan] D2. Pronounced and styled "Dikta"; the menubar mark stays the name-agnostic "spoken-mark" from the branding plan D4 (a "D" wordmark variant is an option but not required — the spoken-mark already works and is decided).

**D2 — Rename mapping.** The exact source/target mapping, so the rename is mechanical and reviewable:

| Current | Renamed to | Notes |
|---------|-----------|-------|
| repo dir `voice-dictate/` + GitHub slug `thanpolas/voice-dictate` | `dikta/` + `thanpolas/dikta` | External; see [D4][external-anchor]. |
| `hammerspoon/voice-dictate.lua` | `hammerspoon/dikta.lua` | Main module. |
| `hammerspoon/voice-dictate-mic.lua` | `hammerspoon/dikta-mic.lua` | Mic picker sibling. |
| `~/.hammerspoon/voice-dictate-config.lua` | `~/.hammerspoon/dikta-config.lua` | Filename carries the product name. |
| `require("voice-dictate"/"-mic"/"-config")` | `require("dikta"/"dikta-mic"/"dikta-config")` | Must move with the filenames in one commit. |
| `init.lua` appended `require("voice-dictate").start()` | `require("dikta").start()` | Written by `install/hammerspoon.sh`. |
| `bin/dictate.sh` + `dictate_sh` config key | `bin/dikta.sh` + `dikta_sh` | Internal entry point; lower urgency but do it for consistency. |
| `bin/config.local.sh` | unchanged | Generic name, not branded. |
| NSUserDefaults key `voice-dictate.audioDevice` | `dikta.audioDevice` | Migrate — see [D3][migration-anchor]. |
| `/tmp/voice-dictate-<ts>.wav`, `/tmp/voice-dictate-ghost-watch.log` | `/tmp/dikta-<ts>.wav`, `/tmp/dikta-ghost-watch.log` | Update `monitor-ghosts.sh`'s `pgrep` pattern to match. |
| Strings: `print("voice-dictate: ready…")`, `notify("voice-dictate", …)` | `"dikta: ready…"`, `notify("Dikta", …)` | User-visible. |
| All docs: `README.md`, `CLAUDE.md`, `INVENTORY.md`, every folder README, `@fileoverview` headers | `Dikta` / `dikta` as appropriate | Live docs only; frozen plans excluded. |

**D3 — Migrate the saved mic via a read-fallback, not a destructive move.**
<a id="migration-anchor"></a>
In the renamed mic module, `loadAudioDevice()` reads the new key `dikta.audioDevice`; if unset, it falls back to reading the old `voice-dictate.audioDevice`, and if that is set, writes it forward to the new key once. This makes the migration self-healing on first use with no install-time step required, and is idempotent. Optionally, `install/migration.sh` also performs the one-time `defaults`-level copy for users who update without opening the menu first. Belt-and-suspenders; the read-fallback alone is sufficient and is the floor.

**D4 — The GitHub slug / folder rename is the one deferred step, cut over on the user's go.**
<a id="external-anchor"></a>
Renaming the GitHub repo (`voice-dictate` → `dikta`) and the local `voice-dictate/` directory, and updating the clone URL in [README.md][readme], is external and has no in-repo load-bearing effect — GitHub auto-redirects the old slug. Per the [branding plan][branding-plan] D1 this is the single piece the user explicitly defers: cut over the folder + slug deliberately on their go, not automatically. Everything *inside* the tree renames now; this step can lag the in-repo rename indefinitely without breaking anything.

**D5 — Frozen docs get a superseding note, not a rewrite.**
The [v0.1 spec][v01-spec] and older plans keep the `voice-dictate` name in their bodies (historical accuracy). This rename plan is the pointer that says "the product is now Dikta." No edits to frozen plans.

**D6 — Sequence as atomic commits.** Per [conventions.md][conventions-md] § Atomic commits, each logical unit is its own commit, ordered so each leaves a loadable repo. See [Sequence of work][sequence-anchor]. The require-graph rename (Lua files + their `require()` calls + the symlink/init.lua patch in `install/hammerspoon.sh`) is *one* commit because no intermediate state loads.

**D7 — Availability is due diligence, not a gate.**
<a id="availability-anchor"></a>
The name is locked to Dikta ([branding plan][branding-plan] D2), so the internal rename is not blocked on this. Still, before a *public launch*, verify Dikta is clear: GitHub org/repo, any future Homebrew tap collision, a domain if wanted, macOS App Store name collision, and a basic trademark search. A soft collision (a crowded package name, an unrelated similar repo) does not change the decision. Only a hard trademark conflict warrants action — escalate it to the user rather than auto-switching names. The codebase rename proceeds regardless of this check.

## Sequence of work

<a id="sequence-anchor"></a>

1. **Availability due-diligence ([D7][availability-anchor]).** Run it for public-launch safety, but it does not block the rename; escalate only a hard trademark conflict to the user. The codebase rename proceeds either way.
2. **Lua require-graph rename (one commit).** Rename `hammerspoon/voice-dictate*.lua` → `dikta*.lua`, update every `require()` call, update the config filename `dikta-config.lua`, and update `install/hammerspoon.sh`'s symlink targets + the `init.lua` patch string together. Repo still loads after this commit.
3. **Mic-key migration (one commit).** Add the read-fallback in the renamed mic module ([D3][migration-anchor]); optionally the `install/migration.sh` copy. New key `dikta.audioDevice`.
4. **Shell entry rename (one commit).** `bin/dictate.sh` → `bin/dikta.sh`, the `dikta_sh` config key, references in test scripts and `monitor-ghosts.sh` (including the tmp-prefix `pgrep` pattern and the ghost-watch log path).
5. **User-visible strings + temp-file prefixes (one commit).** `print`/`notify` strings, `/tmp/dikta-<ts>.wav` in the wav-path helper.
6. **Docs (one commit).** `README.md`, `CLAUDE.md`, `INVENTORY.md`, folder READMEs, `@fileoverview` headers. Frozen plans untouched ([D5][migration-anchor]).
7. **External rename ([D4][external-anchor]).** GitHub slug + clone URL + local dir. Lag-tolerant; can follow the merge.
8. **Manual verification** (Lua is manually verified per A4 in [CLAUDE.md][claude-md]): fresh `hs.reload()` loads `dikta`, hotkeys work, an existing saved mic survives (set `voice-dictate.audioDevice`, confirm it carries to `dikta.audioDevice`), record→transcribe→paste round-trips.

## Cross-doc effects

- **`INVENTORY.md`** — the `hammerspoon/` entries change filenames (`dikta.lua`, `dikta-mic.lua`); the `bin/` entry changes (`dikta.sh`); root files and folder hooks lose the `voice-dictate` name. Handled in the docs commit (step 6); the inventory is kept in sync per the CDE inventory responsibility.
- **[bin/README.md][bin-readme]** + **[hammerspoon/README.md][hs-readme]** — filenames, command names (`dikta.sh …`), config keys (`dikta_sh`), the NSUserDefaults key, and the `loadAudioDevice` read-fallback behaviour.
- **[README.md][readme]** — product name throughout, clone URL.
- **[install plan][install-plan]** — its `install/config.sh`, `install/hammerspoon.sh`, and `install/migration.sh` sections gain Dikta names/keys + the mic migration; coordinate per the [mid-flight constraint][constraints-anchor].
- **[branding-identity plan][branding-plan]** — already records the decision and points here; no further edit.
- **Frozen plans** — no edits (D5).

## Risks and open questions

- **Mic-selection orphaning** — mitigated by the [D3][migration-anchor] read-fallback. Verify the fallback path in step 8; it is the single most user-affecting item.
- **Collision with in-flight install-UX work** — the rename and the [install plan][install-plan] touch the same `install/` files. Risk of merge churn or a half-renamed config generator. Mitigation: land the rename after the bootstrap helpers stabilise, or explicitly carve the overlapping lines. Flagged, not yet resolved.
- **"Dikta" availability ([D7][availability-anchor]) is unverified.** Not a blocker for the internal rename (the name is locked), but a hard trademark conflict discovered post-launch would be expensive — run the check before going public and escalate any conflict rather than silently renaming.
- **Partial-rename broken state** — mitigated by the atomic-commit sequencing in D6: the require-graph rename is one commit so no intermediate state fails to load.
- **Open question — keep a `voice-dictate` compatibility shim for one version?** Since unpublished with no external users, probably unnecessary. Decide explicitly: most likely "no shim — clean cut," but confirm there are no other local machines mid-install before deleting the old names.
- **Open question — rename `bin/config.local.sh`?** Left unchanged in D2 as a generic, unbranded name. Revisit only if a contributor finds the mixed naming confusing.

[branding-plan]: 2026-05-26-branding-identity.md
[install-plan]: 2026-05-25-install-ux-bootstrap.md
[v01-spec]: 2026-05-20-v0.1-spec.md
[conventions-md]: ../conventions.md
[readme]: ../../README.md
[claude-md]: ../../CLAUDE.md
[bin-readme]: ../../bin/README.md
[hs-readme]: ../../hammerspoon/README.md
[rename-radius]: 2026-05-26-branding-identity.md#rename-radius-anchor
[migration-anchor]: #migration-anchor
[availability-anchor]: #availability-anchor
[external-anchor]: #external-anchor
[sequence-anchor]: #sequence-anchor
[constraints-anchor]: #constraints-and-forces
