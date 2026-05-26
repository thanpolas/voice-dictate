# 2026-05-26 — Cursor loader: on-pointer visual feedback during transcription

Owner: thanpolas. Status: draft — feasibility open questions flagged.

## Goal

While transcription runs (after the user stops recording, before the paste fires), give visual feedback **at the mouse cursor** that work is in progress — "make the cursor a loader." The user gets local feedback where their eyes already are, without glancing at the menubar.

This is the same lifecycle as today's menubar spinner ([`voice-dictate.lua`][vd-lua] `startSpinner()` / `stopSpinner()`, driven by `hs.timer.doEvery` at [`SPINNER_INTERVAL_S`][vd-lua]): start when transcription begins inside `transcribeAndPaste`, stop on paste success or failure. The only thing that changes is **where** and **how** the spinner is rendered — near the pointer instead of (or in addition to) the menubar.

This plan deliberately revisits a v0.1 non-goal. The [v0.1 spec][v01-spec] froze "visual overlay (canvas with waveform)" out of scope to keep the first cut shippable; the menubar spinner was the agreed minimum. This plan reopens **on-screen visual feedback** narrowly — a transcription-progress indicator at the cursor, not a waveform — and treats it as an additive layer that does not change the recording or transcription path.

## Constraints and forces

- macOS-only, Apple Silicon, Hammerspoon-hosted. Shell + Lua only — no new runtime ([conventions.md][conventions-md] § Shell/Lua specifics).
- **No public API forces the system busy/wait cursor.** The spinning-wait cursor is drawn by the window server only when an app stops servicing its event loop for ~2–4s; it is not application-controllable. `NSCursor` only sets a cursor image while *your own app* is frontmost over *its own views* — it cannot recolor or animate the global pointer over other apps. A true "OS busy cursor" is therefore **not achievable** from Hammerspoon. See [Open questions][openq] — this is the load-bearing constraint and it is settled by research, not assumption.
- The realistic mechanism is a small, purely-decorative [`hs.canvas`][hs-canvas] overlay drawn at the mouse location and animated, optionally following the pointer.
- The overlay must be **click-through and focus-inert** — it must never steal a click, never activate Hammerspoon's windows, never change which app is frontmost. A dictation tool that eats the user's next click is worse than no feedback at all.
- File-size discipline: [`voice-dictate.lua`][vd-lua] is already ~210 lines against a 200 soft / 300 hard cap ([conventions.md][conventions-md] § File and function size). The [hammerspoon README][hs-readme] § Size budget already names "visual feedback layer (canvas)" as a split trigger. **This work lands as a new sibling module** (`voice-dictate-cursor.lua`), not as additions to the main file.
- Reload safety: any timer / eventtap / canvas this introduces must be torn down by `M.stop()` so `hs.reload()` stays clean ([conventions.md][conventions-md] § Lua specifics).

## Decisions

**D1 — No system cursor manipulation. Render a decorative `hs.canvas` overlay instead.**
We do not attempt `NSCursor`, no private window-server calls, no "fake beachball." The deliverable is a small animated canvas positioned at the pointer. This is stated up front so no later reviewer re-litigates it. The phrase "make the cursor a loader" is satisfied *visually* (a spinner rides with the pointer), not literally (the OS pointer glyph is unchanged).

**D2 — New sibling module `voice-dictate-cursor.lua`, mirroring the mic-module split.**
Public surface, intentionally tiny:

```lua
local cursorLoader = require("voice-dictate-cursor")
cursorLoader.start()  -- show + animate the on-cursor loader (idempotent)
cursorLoader.stop()   -- hide + tear down canvas, timer, eventtap (safe to repeat)
```

`transcribeAndPaste` calls `cursorLoader.start()` exactly where it calls `startSpinner()` today, and `cursorLoader.stop()` exactly where it calls `stopSpinner()` — both on the success and failure branches. The menubar spinner stays (see D6); the two are independent. `M.stop()` in the main module also calls `cursorLoader.stop()` for reload safety.

**D3 — Canvas is decorative and click-through by construction.**
Per [`hs.canvas`][hs-canvas]: a canvas that (a) never sets a `mouseCallback`, (b) never calls `canvasMouseEvents(...)`, and (c) sets no `trackMouse*` element attributes is purely decorative and passes all mouse events through. We rely on exactly this recipe. We do **not** call `clickActivating` (only relevant once a click callback exists). Acceptance check: with the loader visible, clicking through it lands in the app underneath and does not bring Hammerspoon forward.

**D4 — Window level and behavior tuned for "always visible, never interfering."**
- `level(hs.canvas.windowLevels.overlay)` — above normal/floating windows so the loader is visible over the focused app, but it carries no input focus. (`screenSaver` is higher than needed and risks covering system UI; `overlay` is the right tier for a decorative HUD.)
- `behavior` set to `{canJoinAllSpaces, stationary}` via `behaviorAsLabels` so the loader shows on the current Space (including full-screen app Spaces) and does not animate during Space switches. This addresses the Spaces / full-screen concern directly.

**D5 — Animation: reuse the braille-frame model; advance on a `hs.timer.doEvery` at `SPINNER_INTERVAL_S`.**
The visual vocabulary is consistent with the menubar: same [`SPINNER_FRAMES`][vd-lua] braille set rendered as a `text` element, or a rotating `arc` (decided in D8). Frame advance uses the same 80ms cadence the user already sees in the menubar, so the two indicators stay visually coherent. Frame-advance and position-follow are **separate concerns** with separate update rates (see D7).

**D6 — Keep the menubar spinner. The cursor loader is additive, not a replacement.**
The menubar spinner is cheap, proven, and the fallback when the canvas path is disabled or fails to draw (e.g. an exotic display config). Both run during transcription. A future plan may make this configurable (`cfg.cursor_loader = true|false`); for this plan the loader is on by default with the menubar spinner as the always-on baseline. The do-nothing baseline — menubar spinner only — remains the graceful-degradation target.

**D7 — Follow-the-cursor strategy: prefer an `hs.eventtap` mouseMoved observer over a high-frequency timer.**
Two ways to make the loader track the pointer; they trade differently and the choice is the riskiest design call here (flagged in [Open questions][openq]):

- **(a) `hs.timer.doEvery(~1/60, reposition)`** — poll `hs.mouse.absolutePosition()` 60×/s and move the canvas via `topLeft(...)`. Simple, but burns CPU for the *entire* transcription duration (several seconds) even when the mouse is still, and 60Hz polling can still visibly lag fast mouse motion (poll-then-draw is always one tick behind).
- **(b) `hs.eventtap.new({mouseMoved}, reposition)`** — reposition only when the pointer actually moves, driven by the OS event stream. Zero cost when the mouse is still (the common case mid-transcription); naturally synced to real motion. This is the same eventtap family the PTT handler already uses ([`onFlagsChanged`][vd-lua]), and the handler returns `false` to never swallow events ([conventions.md][conventions-md] § Lua specifics).

**Recommended: (b) eventtap mouseMoved observer**, with the *frame-advance* timer (D5) still on `hs.timer.doEvery`. The eventtap repositions the canvas; the timer only swaps the glyph. This keeps idle cost near the timer's 80ms tick rather than a 60Hz reposition loop. Initial placement on `start()` reads `hs.mouse.absolutePosition()` once so the loader appears immediately even before the first move.

**D8 — Glyph: start with a `text` element rendering the braille frames; evaluate an `arc` spinner only if the text looks wrong at the hotspot.**
`text` reuses [`SPINNER_FRAMES`][vd-lua] verbatim — lowest-effort, guaranteed visual parity with the menubar. Risk: a tiny glyph offset from the pointer hotspot can read as "detached." Fallback is a drawn `arc` (rotating partial ring) which centers cleanly on a known point. Decide during the spike (sequence step 2); do not pre-build both.

**D9 — Positioning offset, Retina, and the canvas size are derived, not hardcoded.**
The canvas is a small fixed square (e.g. 20×20 points) offset down-right of the pointer hotspot so it sits where a busy cursor would, not under the click point. `hs.mouse.absolutePosition()` returns desktop-space points (resolution-independent), and `hs.canvas` frames are in points, so Retina backing-scale is handled by the framework — we do **not** multiply by `screen:currentMode().scale`. Multi-display: absolute coordinates span all displays, so the same `topLeft(...)` math works across monitors with no per-screen branching.

## Sequence of work

1. **CDE first.** Add `voice-dictate-cursor.lua` stub (fileoverview + `M.start`/`M.stop` no-ops) and a `## voice-dictate-cursor.lua` section to the [hammerspoon README][hs-readme] describing what it owns, the click-through invariant (D3), and the level/behavior choices (D4). No behavior change yet.
2. **Spike the visual (D8).** In the stub, draw a static canvas at a fixed point with the braille `text` element; confirm it renders, is click-through, sits at the right offset, and looks coherent at Retina and non-Retina. Decide text vs arc here.
3. **Animate the glyph (D5).** Add the `hs.timer.doEvery(SPINNER_INTERVAL_S, ...)` frame-advance against the braille frames. Verify cadence matches the menubar spinner.
4. **Follow the cursor (D7).** Add the `hs.eventtap` mouseMoved observer that repositions via `topLeft(...)`; place once on `start()`. Verify smooth tracking with no swallowed clicks and `false` always returned from the handler.
5. **Wire into the lifecycle (D2).** Call `cursorLoader.start()` / `.stop()` from `transcribeAndPaste` alongside the existing menubar spinner calls, on both success and failure branches. Add `cursorLoader.stop()` to the main module's `M.stop()`.
6. **Reload-safety pass.** Confirm `cursorLoader.stop()` tears down canvas + timer + eventtap with no accumulation across `hs.reload()`; confirm `start()` is idempotent (calls `stop()` first).
7. **Manual verification matrix** (audio/UI surface is not unit-testable per [conventions.md][conventions-md] § A4): single display, dual display, Retina + non-Retina, full-screen app Space, Space switch mid-transcription, click-through into the underlying app, a transcription long enough (~3–5s) to watch idle CPU.
8. **Update [hammerspoon README][hs-readme]** Size-budget and Failure-modes sections with the as-built behavior and the menubar-spinner fallback (D6).

## Cross-doc effects

- [hammerspoon README][hs-readme] — new `## voice-dictate-cursor.lua` section; Size-budget note that the canvas split trigger has now fired; Failure-modes entry for "canvas fails to draw → menubar spinner remains."
- `INVENTORY.md` — new `hammerspoon/voice-dictate-cursor.lua` entry. (Owner updates per CDE; **not edited by this plan's author per task scope** — flag for the implementing change.)
- [v0.1 spec][v01-spec] — stays frozen as historical. This plan is the source of truth that the "visual overlay" non-goal is partially reopened, narrowly, for transcription progress. No edit to the frozen spec.
- No change to `bin/` — recording and transcription paths are untouched.

## Interaction with in-flight plans

- **[Cursor lock + async paste (Goal 2a)][p-2a].** That plan captures the cursor/window position at recording end (`Tend`) so the paste lands in the right place even if the user has moved on. This raises a direct question for the loader: if the user roams to another window during transcription, should the loader **follow the now-roaming live cursor** (D7) or **sit at the locked `Tend` location** where the paste will actually land? Argument for following the live cursor: it is local feedback, and "where my pointer is" is where the user is looking. Argument for pinning to `Tend`: it previews where text will appear and avoids implying the cursor itself is busy. **Leaning: follow the live cursor** (matches the literal "make the cursor a loader" intent and is simpler — no dependency on 2a's `Tend` value). If 2a lands first and exposes `Tend`, a pinned variant becomes a cheap config option. Flagged as an [open question][openq].
- **[Streaming transcription (Goal 2c)][p-2c].** With streaming, "transcribing" is not a discrete spinner-then-done phase — partial text arrives continuously and the end is fuzzy. A spinner that means "working, please wait" loses meaning when output is already flowing. Under streaming, the cursor loader likely either (a) goes away entirely in favor of the streamed text being its own feedback, or (b) becomes a subtle "still receiving" pulse that stops at end-of-stream. This is **out of scope here** and noted so the streaming plan owns the decision; this plan targets the current discrete stop-then-transcribe-then-paste flow.

## Risks

- **Follow-jank / perf is the headline risk.** A canvas repositioned at high frequency for several seconds can stutter, lag fast pointer motion, or burn CPU/battery. D7's eventtap-driven reposition mitigates the idle case (zero cost when still) but fast flicks may still show the loader trailing the pointer by a frame. Mitigation: the eventtap path avoids polling entirely; if trailing is unacceptable, a small fixed overlay near `Tend` that does **not** follow (alternative (ii) below) sidesteps motion-tracking altogether.
- **Click-stealing regression.** If the click-through recipe (D3) is ever broken — e.g. a future edit adds a `mouseCallback` — the loader silently starts eating the user's next click. Mitigation: explicit acceptance test (step 4/7) and a one-line invariant comment in the module.
- **Focus / activation surprises.** A canvas at the wrong window level can pull Hammerspoon forward or cover system UI. Mitigation: `overlay` level + decorative-only config (D4); verified in the matrix.
- **Visual incoherence at the hotspot.** A glyph that floats off the pointer reads as a bug, not feedback. Mitigation: D8 offset tuning + text-vs-arc decision during the spike.
- **Module-count creep.** This is the third Lua file. Acceptable — it is a genuinely separate concern and the README already predicted the split — but watch that `start`/`stop` wiring in the main module stays thin.

## Open questions

- **Follow vs pin (2a interaction).** Settled only once 2a's `Tend` contract exists. Default to following the live cursor; revisit if 2a ships a pinned-paste model that users find more intuitive.
- **Three rendering strategies — when is each right?**
  - **(i) Canvas spinner following the cursor (this plan's default, D7).** Best when the user may be looking anywhere and we want feedback exactly under their gaze. Highest implementation + perf risk.
  - **(ii) Fixed small overlay near the cursor's end position (no follow).** Best if jank from (i) proves unacceptable, or once 2a pins paste to `Tend` — show the loader where the text will land, statically. Far simpler; no eventtap, no reposition loop. A strong fallback.
  - **(iii) Menubar spinner only (do-nothing baseline, D6).** Already shipped, zero risk. Appropriate if on-cursor feedback proves janky or distracting in real use, or for low-power situations. This is the graceful-degradation floor, not a failure.
- **Glyph form (D8):** braille `text` vs drawn `arc` — decide in the spike.
- **Default on/off:** ship loader on-by-default, or behind a `cfg.cursor_loader` flag from day one? Leaning on-by-default with the menubar baseline always present; a flag is a trivial later addition.
- **Does `overlay` level cover full-screen video / other HUDs acceptably**, or does it need `status`? Resolve in the multi-Space matrix step.

[vd-lua]: ../../hammerspoon/voice-dictate.lua
[hs-readme]: ../../hammerspoon/README.md
[conventions-md]: ../conventions.md
[v01-spec]: 2026-05-20-v0.1-spec.md
[p-2a]: 2026-05-26-cursor-lock-async-paste.md
[p-2c]: 2026-05-26-streaming-transcription.md
[hs-canvas]: https://www.hammerspoon.org/docs/hs.canvas.html
[openq]: #open-questions
