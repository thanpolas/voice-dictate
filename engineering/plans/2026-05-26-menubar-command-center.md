# 2026-05-26 — Menubar command center and hiding the Hammerspoon icon

Owner: thanpolas. Status: draft — menu structure proposed; idle icon consumes the [branding plan][branding-plan]; minor open questions flagged.

## Goal

Make voice-dictate's own menubar item the single point of command for the tool, and hide Hammerspoon's default menubar icon so the user sees one icon, not two. Today the custom menubar item exists but its dropdown shows *only* the mic picker; everything else (reload, console, preferences) is reached through Hammerspoon's separate icon. This plan turns the custom item into a full command center and removes the Hammerspoon icon — which forces a hard requirement: the two Hammerspoon functions the user actually needs day-to-day (**Open Console**, **Reload Config**) and an escape hatch to **restore the Hammerspoon icon** must move into our menu, or hiding it would strand the user.

This plan owns the menu structure, the icon-hiding, and the action wiring. It consumes the menubar *mark* (the idle glyph) from the [branding plan][branding-plan] but does not depend on it — the menu restructure ships independently of the icon asset.

## Constraints and forces

- **Hiding Hammerspoon's icon removes the user's built-in access to Console and Reload.** Hammerspoon's own menubar icon is the normal way to open the Console, reload config, and reach Preferences. The moment we hide it (the headline ask), our menu becomes the *only* control surface — so it must carry those functions. This is the forcing function for menu items 1b.
- **The menubar item already exists and is callback-driven.** In [voice-dictate.lua][lua-mod], `M.start()` does `menubar = hs.menubar.new()` then `menubar:setMenu(mic.buildMicMenu)`. Passing the *function* (not a built table) means Hammerspoon re-invokes it on every open, which is what gives the mic picker its live device rescan. Any redesign must preserve the callback form so both the mic rescan and live state reflection keep working.
- **Three live states already exist:** idle (`MENUBAR_IDLE` = `○`), recording (`MENUBAR_RECORDING` = `● REC`), transcribing (`SPINNER_FRAMES` braille spinner). The menu's status line and Start/Stop label must reflect them.
- **Reload safety is load-bearing.** `M.start()` calls `M.stop()` first so `hs.reload()` is always safe ([conventions.md][conventions-md] § Lua specifics). Icon-hiding has to fit this lifecycle without leaving the user with *zero* icons if our module ever fails to mount.
- **File-size cap.** [voice-dictate.lua][lua-mod] is ~210 lines against a 200-line soft / 300-line hard cap. A full menu builder plus action handlers is a new logical concern and would push it well past the cap — [conventions.md][conventions-md] § split triggers ("a new logical concern is introduced") says extract. The [hammerspoon README][hs-readme] § Size budget already names a "visual feedback layer" as a future split trigger; the command center is the same kind of trigger.
- **The markdown rules from [conventions.md][conventions-md] apply to this document:** reference-style links, no `---` horizontal rules.

## Proposed menu (the 1a deliverable)

<a id="menu-anchor"></a>

Clicking the custom menubar icon opens this dropdown. `✓` marks the active mic; the status line and the Start/Stop label are state-driven; `⌘⇧D` is the toggle hotkey hint, derived from `TOGGLE_MODS` + `TOGGLE_KEY`.

```
voice-dictate — Idle               ← status header (disabled): Idle / Recording… / Transcribing…
  ────────────────────────
  Start Dictation        ⌘⇧D       ← flips to "Stop Dictation" while recording
  ────────────────────────
  Microphone                    ▸   ← submenu: the existing live-rescan mic picker
      ✓ MacBook Pro Microphone
        External USB Mic
  ────────────────────────
  Open Console                       → hs.openConsole()      [1b — required]
  Reload Config                      → hs.reload()           [1b — required]
  ────────────────────────
  Show Hammerspoon Menu Icon         → hs.menuIcon(true)     [1b — restore escape hatch]
  ────────────────────────
  About voice-dictate                → version + repo link
```

Rationale for what is in and what is out:

- **Start/Stop Dictation** earns the top slot — it is the one action a user might reach for by mouse when a hotkey is awkward (e.g. presenting, or a key is intercepted by another app). It mirrors the existing toggle.
- **Microphone** moves from being the *whole* menu to a submenu, preserving the per-open rescan.
- **Open Console** and **Reload Config** are mandatory (1b) — they replace what the hidden Hammerspoon icon provided. These are the two functions a user of a Hammerspoon-based tool reaches for most.
- **Show Hammerspoon Menu Icon** is the restore escape hatch (1b). Worded as "Menu Icon" to be unambiguous about *which* Hammerspoon icon.
- **About** is a low-stakes affordance for version + repo link; cheap and conventional.
- **Deliberately omitted:** a "Quit / Disable dictation" item that calls `M.stop()`. With the Hammerspoon icon hidden, `M.stop()` would tear down our menu and leave the user with no icon at all and no obvious way back. Disabling is a deliberate, rare act — leave it to editing `init.lua` or the Console. See [Open questions][open-questions-anchor].

## Decisions

**D1 — Extract the menu into a new sibling module `hammerspoon/voice-dictate-menu.lua`.**
The command center is a distinct logical concern and would blow [voice-dictate.lua][lua-mod] past its size cap. Add a sibling module (the same pattern as [voice-dictate-mic.lua][mic-mod]) that owns the menu table and its action handlers. To avoid a circular `require` (the menu needs to start/stop recording and read state, which live in the main module), the menu module exposes a builder that takes an injected interface rather than requiring the main module back:

```lua
-- voice-dictate-menu.lua (sketch)
local M = {}
local mic = require("voice-dictate-mic")
--- Build the dropdown. `ctl` injects the main module's controls + state reads.
--- @param ctl table { onToggle, isRecording, isTranscribing, hotkeyHint }
--- @return table Menu descriptors for hs.menubar:setMenu().
function M.build(ctl) ... end
return M
```

The main module wires it once: `menubar:setMenu(function() return menu.build(ctl) end)`. The wrapping function keeps the callback form so the mic submenu re-scans and the status line re-reads state on every open.

**D2 — Hide the Hammerspoon menu icon in `M.start()` via `hs.menuIcon(false)`; restore via `hs.menuIcon(true)`.**
`hs.menuIcon([state])` toggles Hammerspoon's own menubar icon at runtime (verify the exact signature against the [hs docs][hs-funcs] during implementation). Hide it at the end of `M.start()`, once our own menubar is confirmed mounted — never before, so a mount failure can't leave the user iconless. The "Show Hammerspoon Menu Icon" menu item calls `hs.menuIcon(true)` as a live escape hatch.

**D3 — Do NOT restore the Hammerspoon icon in `M.stop()`.**
`M.stop()` runs on every `hs.reload()` (via `M.start()` → `M.stop()`). Restoring there would make the icon flicker visible→hidden on every reload. Leave the icon hidden across the stop/start cycle; `M.start()` re-asserts `hs.menuIcon(false)` each time. The only path that *shows* it is the explicit menu action or the Console. Accept the small risk in [D5][safety-anchor].

**D4 — Status reflection and the Start/Stop label come from injected state reads.**
The menu builder calls `ctl.isRecording()` and `ctl.isTranscribing()` to render the header (`Idle` / `Recording…` / `Transcribing…`) and to choose the action label (`Start Dictation` vs `Stop Dictation`). The main module already tracks `recording`; "transcribing" is currently implicit in `spinnerTimer ~= nil`. Expose both via tiny accessor closures passed in `ctl` — no new module-level state. `Start Dictation` calls the same path as `onToggleTap`.

**D5 — Recovery path for the iconless-lockout edge case, documented, not coded.**
<a id="safety-anchor"></a>
The only way to end up with no menubar icon at all is: our module mounts successfully (so it hides Hammerspoon's icon), then our own menubar later fails or is deleted without a reload. This is unlikely given reload safety, but the recovery must be written down in the [hammerspoon README][hs-readme]: open Hammerspoon's Preferences (Spotlight → Hammerspoon, or the dock icon if shown) and re-enable "Show menu icon", or run `hs.menuIcon(true)` from the Console (reachable via the dock icon or `open -a Hammerspoon`). If our module *fails to load*, `M.start()` never runs, so the icon is never hidden — the dangerous case requires partial success only.

**D6 — Make hiding optional via a config flag `hide_hammerspoon_icon` (default `true`).**
Add the key to `~/.hammerspoon/voice-dictate-config.lua` (written by `install/config.sh`) so a user who wants Hammerspoon's icon back *permanently* sets it `false` rather than relying on the one-shot menu action (which `hs.reload()` would undo, per [D3][safety-anchor]). `M.start()` reads the flag and only hides when true. This turns the restore escape hatch into a durable preference. Default `true` honors the headline ask.

**D7 — The idle icon is consumed from the [branding plan][branding-plan], and is independent of this work.**
This plan ships the menu restructure + icon-hiding against today's `○` idle glyph. When the [branding plan][branding-plan] (D4/D5) lands the `hs.canvas` template mark, the idle glyph swaps in; recording stays `● REC`, transcribing stays the spinner. The two plans compose and can ship in either order. Sequence the commits so neither blocks the other.

## Sequence of work

1. Create `hammerspoon/voice-dictate-menu.lua` with `M.build(ctl)` returning the [proposed menu][menu-anchor]; embed the mic picker as a submenu by calling `mic.buildMicMenu()` inside the builder.
2. In [voice-dictate.lua][lua-mod]: add the `ctl` interface (toggle + `isRecording`/`isTranscribing` accessors + hotkey-hint string), and rewire `M.start()` to `menubar:setMenu(function() return menu.build(ctl) end)`.
3. Add `hs.menuIcon(false)` to the tail of `M.start()` gated on the `hide_hammerspoon_icon` config flag; wire the menu's "Show Hammerspoon Menu Icon" item to `hs.menuIcon(true)`, "Open Console" to `hs.openConsole()`, "Reload Config" to `hs.reload()`.
4. Add `hide_hammerspoon_icon` (default `true`) to the config template in `install/config.sh` and document it.
5. Manual verification (Lua is manually verified per A4): menu opens with live mic rescan and correct state header; Start/Stop works from the menu; Hammerspoon icon is gone on load; "Show Hammerspoon Menu Icon" brings it back; `hs.reload()` re-hides it; Console and Reload actions fire.
6. Update cross-docs (below) in the same change.

## Cross-doc effects

- **`INVENTORY.md`** — add the new `hammerspoon/voice-dictate-menu.lua` entry under the `hammerspoon/` section (handled centrally by the orchestrator when the module is created).
- **[hammerspoon/README.md][hs-readme]** — document the command-center menu, the icon-hiding behavior + the `hide_hammerspoon_icon` config key, the new sibling module, and the [recovery path][safety-anchor]; revise the Configurable-values table; bump the size-budget note.
- **`install/config.sh` + `voice-dictate-config.lua`** — new `hide_hammerspoon_icon` key.
- **[README.md][readme]** — usage/menubar section: one menu instead of two icons; note Console/Reload live in our menu now.
- **[branding plan][branding-plan]** — its D4/D5 idle-icon work plugs into the menu's idle representation; no edit to that plan, just a consuming reference.

## Risks and open questions

<a id="open-questions-anchor"></a>

- **Iconless lockout (low probability, high annoyance).** Covered by [D5][safety-anchor]'s documented recovery and by hiding only after a confirmed mount. Worth a second look during implementation that no error path between `hs.menubar.new()` and `hs.menuIcon(false)` can drop our menu while the HS icon is already hidden.
- **`hs.reload()` undoes the one-shot restore.** Expected behavior per [D3][safety-anchor]; the durable answer is the [D6][safety-anchor] config flag. Confirm the wording in the menu ("Show…") doesn't imply permanence.
- **`hs.menuIcon` signature/behavior unverified in-repo.** Confirm the exact API (argument form, return) against the installed Hammerspoon version before relying on it.
- **Menu-item hotkey hint vs real shortcut.** `hs.menubar` menu items support a `shortcut` field, but it is display/registration-limited and won't represent `⌘⇧D` faithfully. Decision: render the hint as title text, not via `shortcut`. Verify during implementation.
- **Open question — a "Disable dictation" item?** Omitted by default (see [proposed menu][menu-anchor] rationale) because it would strand an iconless user. Revisit only if paired with an always-available re-enable path.
- **Open question — adopt D6 now or defer?** The config flag is small but touches `install/config.sh`. If the install-UX bootstrap work ([install plan][install-plan]) is mid-flight, coordinate so the new key lands cleanly in the generated config rather than racing it.

[branding-plan]: 2026-05-26-branding-identity.md
[install-plan]: 2026-05-25-install-ux-bootstrap.md
[conventions-md]: ../conventions.md
[lua-mod]: ../../hammerspoon/voice-dictate.lua
[mic-mod]: ../../hammerspoon/voice-dictate-mic.lua
[hs-readme]: ../../hammerspoon/README.md
[readme]: ../../README.md
[hs-funcs]: https://www.hammerspoon.org/docs/hs.html
[menu-anchor]: #menu-anchor
[safety-anchor]: #safety-anchor
[open-questions-anchor]: #open-questions-anchor
