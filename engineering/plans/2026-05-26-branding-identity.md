# 2026-05-26 — Branding and visual identity

Owner: thanpolas. Status: draft — name **locked**: Dikta; the rename is forced codebase-wide via the follow-on [rename-to-dikta][rename-plan] plan (only the repo/folder rename is deferred to the user's go). Identity direction proposed.

## Goal

Settle the published brand for this tool before it ships, and propose a visual identity that fits its character: a privacy-first, 100%-on-device dictation tool for macOS, built for anyone who has to work in a language that isn't their first — most acutely the very large population that does not speak English natively. The tool is **language-agnostic**: it solves a global problem and is not tied to any one language or country. Two outputs:

1. The published name: **Dikta**, replacing `voice-dictate` across the entire codebase. The candidates that were weighed are recorded below for posterity, but the decision is locked.
2. A visual-identity direction that is shippable inside this repo's constraints: a monochrome menubar mark rendered from code (no binary asset), plus a small color palette reserved for docs and any future website.

This plan decides *the name and the identity direction only*. The mechanical rename — forcing `Dikta` through every file — is a separate, larger body of work (see [Cross-doc and rename blast radius][rename-radius-anchor]) owned by the follow-on [rename-to-dikta][rename-plan] plan. The single deferred piece is the repository/directory rename, to be cut over when the user is ready.

## Constraints and forces

- **macOS menubar icons are template images.** Per the [hs.menubar][hs-menubar] and [hs.image][hs-image] docs, `setIcon(image, template)` with `template` true (the default) renders the image as a Dark-Mode-aware template — effectively monochrome, auto-inverting to match a light or dark menubar. Color in the glyph is discarded. So brand color lives in docs and any website, never in the menubar mark.
- **The mark must read at ~16–18px.** The menubar item is tiny. Whatever the mark is, it has to survive being shrunk to roughly the cap-height of the menubar text. Detail dies at that size; the mark must be a single confident silhouette.
- **The repo ships Lua + bash only, and symlinks the Lua files.** Per the [v0.1 spec][v01-spec] § File layout and the [install plan][install-plan], `install.sh` symlinks the two Lua modules into `~/.hammerspoon/`. A binary asset adds a new install step (copy or symlink the asset, resolve its path at runtime) and a new file type to the tree. Code-only rendering avoids all of that.
- **Three live states already exist** in [voice-dictate.lua][lua-mod]: idle `MENUBAR_IDLE` (`○`), recording `MENUBAR_RECORDING` (`● REC`), and a 10-frame braille spinner `SPINNER_FRAMES` (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) during transcription. Any new mark has to express all three within the monochrome-template constraint.
- **The rename is cross-cutting.** The string `voice-dictate` is load-bearing in filenames, `require()` calls, config filenames, an NSUserDefaults key, the `hammerspoon://` wiring, and every doc. The cost is real and is enumerated in full below so the follow-on rename plan can execute it without surprises.
- The markdown rules from [conventions.md][conventions-md] apply to this document: reference-style links only, no `---` horizontal rules.

## Decisions

**D1 — Rename to Dikta, forced through the entire codebase. Not opt-in.**
`voice-dictate` is descriptive but generic, forgettable, and unownable as a brand. `Dikta` is short, distinctive, pronounceable in any language, and trivially searchable/trademarkable. The decision is to rename **everywhere** `voice-dictate` appears — module filenames, `require()` calls, config filenames, the NSUserDefaults key, temp-file prefixes, user-visible strings, and all docs. The mechanical sweep is owned by the follow-on [rename-to-dikta][rename-plan] plan and runs in full. The **one** deferred exception is the repository/directory rename (the `voice-dictate/` folder and the GitHub slug `thanpolas/voice-dictate`): it carries external/clone-URL consequences and benefits from a deliberate cut-over, so it waits until the user says go. Everything inside the tree renames now.

**D2 — The name is Dikta. Full stop.**
<a id="name-decision-anchor"></a>
`Dikta` evokes "dictate," is one short memorable token, reads and pronounces cleanly in any language, and yields a clean **D** wordmark for docs (and `D` is already the toggle-hotkey mnemonic). The menubar glyph itself uses the language-neutral spoken-mark from [D4][icon-approach-anchor], not a literal "D". This is the name; it is not reopened.

Candidates weighed before locking Dikta (recorded for posterity, all rejected):

- **Idolect** — from "idiolect" (a person's unique speech); evocative but needs explaining and invites misreads.
- **Vox** — Latin "voice"; too short and heavily used (Vox Media, many apps), unownable bare.
- **Logos** — "word/speech"; carries a loaded English meaning ("a logo") and SEO noise.
- **Parla** — from *parlare*/"to speak"; warm but softer and less distinctive than Dikta.
- **Murmur** — on-theme for a quiet, private tool; prior software uses muddy it.

Availability due-diligence (GitHub org/repo, Homebrew tap, domain, macOS App Store name, trademark) is still worth doing before a public launch, but it does **not** reopen the name — see [OQ1][oq1-anchor].

**D3 — Visual identity direction: a "spoken-mark" — a dot becoming a line.**
The concept is language-neutral and on-brand for Dikta: **a single point (the voice) resolving into text (the line)**. Concretely, a small filled dot with one or two short horizontal strokes to its right — read as "a sound, then words." It maps perfectly onto the existing state language: the idle `○` is already an open dot; the mark is its closed, intentional sibling. The mark must convey: *local* (self-contained, no cloud arrow/globe), *voice* (the dot/pulse), *text output* (the stroke). It must NOT use a microphone cliché or a cloud — both are visually noisy at 16px and the cloud actively contradicts the privacy story.

Palette (docs and website only — never the menubar glyph, which is template-monochrome):

- **Ink** `#16161D` — near-black, primary mark on light backgrounds.
- **Paper** `#F7F5F0` — warm off-white background.
- **Signal** `#E5484D` — a single restrained red, reserved for the *recording* state in docs/marketing and for accent. Mirrors the existing `● REC` semantics.
- **Aegean** `#2D7FF9` — one calm, trustworthy cool accent for links/CTAs. No flag or nationality cues; the brand is language-agnostic.

Keep it to these four. A privacy tool reads as trustworthy when its identity is restrained.

**D4 — Menubar icon: render the mark with `hs.canvas`, not a binary asset, not ASCII.**
<a id="icon-approach-anchor"></a>
Three in-repo options were researched against the [hs.canvas][hs-canvas], [hs.image][hs-image], and [hs.menubar][hs-menubar] docs:

- **`hs.image.imageFromASCII(ascii)`** — renders an [ASCIImage][asciimage]-format grid (points marked by digits/letters; a character used twice draws a line, three-plus draws an ellipse; `#` and `.` and space are passive guides) into an `hs.image`. No binary asset. *Rejected as primary:* the ASCIImage grammar is fiddly for curved/organic marks, point coordinates are coarse at icon scale, and it is harder to tune visually than direct shapes. Good for a quick blocky glyph, not for a polished brand mark.
- **`hs.canvas` shapes → `canvas:imageFromCanvas()` → `menubar:setIcon(image, true)`** — *recommended.* `hs.canvas.new({x=0,y=0,w=18,h=18})`, append `circle` and `segments`/`rectangle` elements with `fillColor` set to opaque black (the template pass discards hue and keeps the silhouette), then `imageFromCanvas()` returns an `hs.image` passed to `setIcon(image, true)` so macOS auto-inverts it for light/dark menubars. Code-only, scalable, no new file type, lives beside the existing Lua. This is the lowest-friction path that still yields a crisp, tunable mark.
- **Shipped template `.pdf`/`.png` set via `menubar:setIcon(path, true)`** — *rejected.* Cleanest rendering and a real designed PDF would look best, but it introduces a binary asset into a symlink-based shell+Lua repo: a new install step to place/resolve the asset, a path constant, and a file type the repo has so far avoided. Defer until there is a website/brand kit that justifies a proper asset pipeline.

Recommended canvas sketch for the **Dikta** spoken-mark (18×18 template, opaque black fill, template flag true):

```lua
-- mark: a voice-dot resolving into a text-stroke
local c = hs.canvas.new({x = 0, y = 0, w = 18, h = 18})
c[1] = { type = "circle",  center = {x = 5, y = 9}, radius = 2.5,
         action = "fill",   fillColor = {white = 0, alpha = 1} }
c[2] = { type = "rectangle", frame = {x = 9.5, y = 7.5, w = 6, h = 1.6},
         action = "fill",   fillColor = {white = 0, alpha = 1} }
c[3] = { type = "rectangle", frame = {x = 9.5, y = 10.5, w = 4, h = 1.6},
         action = "fill",   fillColor = {white = 0, alpha = 1} }
local mark = c:imageFromCanvas()
menubar:setIcon(mark, true)   -- true = template; macOS auto-inverts for light/dark
```

If the user prefers the zero-dependency-on-canvas-geometry route, an ASCIImage fallback for the same dot-plus-strokes silhouette is viable via `hs.menubar:setIcon("ASCII:...")` — but canvas is the recommendation for tunability.

**D5 — State variants within the monochrome-template constraint.**
The new mark replaces the *idle* glyph; recording and transcribing reuse the existing, proven mechanics so we change as little behavior as possible.

- **Idle** — the spoken-mark from [D4][icon-approach-anchor] as a template icon via `setIcon(mark, true)`. Replaces the bare `○` `MENUBAR_IDLE` string. (Optionally keep a no-icon text fallback if `imageFromCanvas` ever returns nil.)
- **Recording** — keep a clearly distinct *filled* state. Two viable monochrome options: (a) swap the icon for a solid filled disc variant of the mark (the dot "lit up"), or (b) keep the current `setTitle("● REC")` text, which is unambiguous and already shipped. Recommendation: keep `● REC` text for v1 of the rebrand — it is the loudest, least-ambiguous recording signal and avoids a second canvas asset on day one. The `Signal` red from [D3][icon-approach-anchor] is used for `● REC` in docs/screenshots, not in the menubar (template can't carry it). Whether to later adopt the filled-disc icon is [OQ4][oq4-anchor].
- **Transcribing** — **keep the existing braille spinner** (`SPINNER_FRAMES`, 80ms). It is the best monochrome busy-indicator available: it animates without color, reads at 16px, and is already wired through `startSpinner`/`stopSpinner` in [lua-mod][lua-mod]. No better monochrome option exists; do not replace it.

Net: only the *idle* representation changes (text glyph → template icon). Recording stays text, transcribing stays the spinner. This keeps the rebrand's menubar surface a one-function change in `setMenubarRecording` plus an icon-builder helper.

## Sequence of work

This plan's deliverable is the decision and direction above. The implementable follow-through, in order:

1. **Implement the menubar mark.** Add an icon-builder helper in [lua-mod][lua-mod] rendering the [D4][icon-approach-anchor] spoken-mark, swap the idle `○` for the canvas template icon, update the [hammerspoon/README.md][hs-readme] menubar-states section. Self-contained and independent of the rename — can ship first.
2. **Execute the rename.** Force `Dikta` through the whole tree via the follow-on [rename-to-dikta][rename-plan] plan (per D1). The repository/directory and GitHub-slug rename waits for the user's explicit go; everything inside the tree renames now.
3. Add the palette and mark spec to any future brand/README section; reserve color for docs only.
4. Manual verification on light and dark menubars that the template icon inverts correctly at native size (per A4 in [CLAUDE.md][claude-md], Hammerspoon Lua is manually verified).

## Cross-doc and rename blast radius

<a id="rename-radius-anchor"></a>
The rename touches the following — enumerated so the follow-on [rename-to-dikta][rename-plan] plan can execute it without surprises. **That plan owns the mechanical sweep; this one does not perform it.**

- **Repository / directory name** — `voice-dictate/` and the GitHub repo slug (`thanpolas/voice-dictate`), plus the clone URL baked into [README.md][readme]. **Deferred** until the user is ready to cut over (per D1); everything below renames now.
- **Lua module filenames + `require()` calls** — `hammerspoon/voice-dictate.lua` and `hammerspoon/voice-dictate-mic.lua`; the `require("voice-dictate-mic")` and `require("voice-dictate-config")` calls in [lua-mod][lua-mod]; the symlink names created by `install/hammerspoon.sh` and the `require()` line appended to the user's `init.lua`.
- **Shell entry point** — `bin/dictate.sh` naming (and any rename of `bin/` references), the `dictate_sh` config key, smoke-test script names under `bin/`.
- **Config filenames** — `bin/config.local.sh` and `~/.hammerspoon/voice-dictate-config.lua` (the latter's filename carries the product name).
- **NSUserDefaults key** — `voice-dictate.audioDevice`, read/written by the mic picker via `hs.settings` ([v0.1 spec][v01-spec] § Mic selection). A rename here orphans existing users' saved mic choice unless migrated — a migration step in `install/migration.sh`.
- **`hammerspoon://` wiring** — any URL-scheme handlers or install-time `open "hammerspoon://..."` reload triggers that reference the module name.
- **Temp-file prefix** — the `/tmp/voice-dictate-<ts>.wav` path in `newWavPath` ([lua-mod][lua-mod]); cosmetic but user-visible.
- **All docs** — [README.md][readme], [CLAUDE.md][claude-md], `INVENTORY.md`, every folder README ([bin/README.md][bin-readme], [hs-readme][hs-readme]), the [install plan][install-plan], and this file; the `@fileoverview` headers; the title in the [v0.1 spec][v01-spec] (frozen — superseding note rather than edit).
- **Install scripts** — the `install/` helpers (paths, symlink targets, log strings) and any `.local/state` markers tied to the name.
- **Branding/social** — the Twitter badge and links in [README.md][readme], the LICENSE copyright line is name-agnostic (person, not product) so it is safe.

Effects of *this* plan (the identity direction):

- **[hammerspoon/README.md][hs-readme]** — menubar-states section gains the icon-builder and the idle/recording/transcribing representation table when [D4][icon-approach-anchor]/[D5][icon-approach-anchor] are implemented.
- **[README.md][readme]** — usage section's "Menubar shows `● REC`" line is reaffirmed (recording stays text); an idle-icon note added when implemented.
- **`INVENTORY.md` / `engineering/plans/README.md`** — new-plan entries are added centrally by the orchestrator, not by this file.

## Risks

- **Template-icon legibility and template behavior are unproven until tested** — see [OQ2][oq2-anchor] and [OQ3][oq3-anchor].
- **Rename migration risk.** The NSUserDefaults key rename orphans the saved mic device unless `install/migration.sh` carries the old value forward. This is the single most user-affecting line item in the blast radius and must be handled in the [rename-to-dikta][rename-plan] plan, not skipped.
- **Scope discipline.** The temptation is to do the menubar mark *and* the whole rename in one sweep. Resist: the identity work ([D4][icon-approach-anchor]/[D5][icon-approach-anchor]) is small and shippable independently; the rename is large and owned by its own plan. Keep them in separate plans and separate commits.

## Open questions

- <a id="oq1-anchor"></a>**OQ1 — Is `Dikta` clear of collisions?** Verify GitHub org/repo, Homebrew tap, domain, macOS App Store name, and a basic trademark search before public launch. Due diligence only — per [D2][name-decision-anchor] it does **not** reopen the name. If a hard trademark conflict surfaces, escalate to the user rather than auto-switching.
- <a id="oq2-anchor"></a>**OQ2 — Does the spoken-mark read at 16–18px?** The [D4][icon-approach-anchor] sketch uses sub-pixel (1.6px) strokes that may blur after template rendering and Retina downscale. Eyeball on a real menubar, light and dark, before it replaces `○`. Fallback: keep the text glyph if it reads as mud.
- <a id="oq3-anchor"></a>**OQ3 — Does a canvas image invert under the template pass?** `setIcon(image, true)` treats the image as a template, but partial-alpha canvas fills can defeat the inversion on some Hammerspoon versions. Use fully opaque black fills as in the [D4][icon-approach-anchor] sketch and confirm on this install.
- <a id="oq4-anchor"></a>**OQ4 — Adopt a filled-disc recording icon later?** [D5][icon-approach-anchor] ships `● REC` text first. Whether to swap recording to a solid-disc icon variant of the mark is deferred, not decided.

[hs-menubar]: https://www.hammerspoon.org/docs/hs.menubar.html
[hs-image]: https://www.hammerspoon.org/docs/hs.image.html
[hs-canvas]: https://www.hammerspoon.org/docs/hs.canvas.html
[asciimage]: https://github.com/cparnot/ASCIImage
[lua-mod]: ../../hammerspoon/voice-dictate.lua
[hs-readme]: ../../hammerspoon/README.md
[bin-readme]: ../../bin/README.md
[readme]: ../../README.md
[claude-md]: ../../CLAUDE.md
[conventions-md]: ../conventions.md
[v01-spec]: 2026-05-20-v0.1-spec.md
[install-plan]: 2026-05-25-install-ux-bootstrap.md
[name-decision-anchor]: #name-decision-anchor
[icon-approach-anchor]: #icon-approach-anchor
[rename-radius-anchor]: #rename-radius-anchor
[rename-plan]: 2026-05-26-rename-to-dikta.md
[oq1-anchor]: #oq1-anchor
[oq2-anchor]: #oq2-anchor
[oq3-anchor]: #oq3-anchor
[oq4-anchor]: #oq4-anchor
