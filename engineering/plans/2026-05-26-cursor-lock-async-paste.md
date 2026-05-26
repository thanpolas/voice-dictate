# 2026-05-26 — Cursor lock and async paste-back

Owner: thanpolas. Status: draft — feasibility open questions flagged.

This plan extends the v0.1 spec ([2026-05-20-v0.1-spec.md][v01-spec]) and intersects the deferred "clipboard save/restore around paste" item named there. It is Goal 2a in the command-center UX track. It does not supersede any shipped plan.

## Goal

Decouple "where the transcript lands" from "what is focused when transcription finishes."

Today the flow is: the user stops recording (call this moment **Tend**), [`transcribeAndPaste(wav)`][lua] runs asynchronously via `hs.task`, and on completion the transcript is written to the pasteboard and a synthetic `Cmd+V` fires into whatever app is frontmost *at paste time*. The user must keep the original field focused and wait — defeating the point of a background transcription.

Desired flow:

1. At **Tend**, capture *where the insertion point was* — the application, the window, and (best-effort) the exact focused text element and caret offset.
2. The user is free to switch windows, read mail, do anything while transcription runs.
3. When the transcript is ready, restore focus to the captured target and insert the text exactly where the caret was at **Tend** — without clobbering the user's current activity any more than necessary.
4. The user's clipboard is preserved across the operation (the deferred v0.2 item, pulled in here because async paste-back forces the clipboard question).

This is a Lua-only change inside [`hammerspoon/voice-dictate.lua`][lua]. The shell side (`dictate.sh`) and the recording state machine are untouched. The seam we build on already exists: transcription is already async (`hs.task`), so the main thread is free between **Tend** and paste — see the 2026-05-24 changelog entry in the v0.1 spec.

## Constraints and forces

- macOS-only, Apple Silicon. Accessibility (AX) APIs via [`hs.axuielement`][axuielement-docs] are fair game; the tool already requires the Accessibility TCC grant for `hs.eventtap.keyStroke` (the paste), so AX *reads* add no new permission prompt — they ride the same grant.
- Lua + shell only. No new runtime. Everything here lives in the Hammerspoon VM.
- The 200-line soft cap from [conventions.md][conventions-md] applies. [`voice-dictate.lua`][lua] is already ~300 lines (the README quotes ~210 but the file has grown). This work introduces a distinct new concern — *focus capture/restore* — which is a clean split trigger under conventions § "File and function size". It should land as a sibling module, not bloat the main file.
- AX behaviour is **wildly app-dependent**. Verified during research: native Cocoa text views expose `AXFocusedUIElement` + `AXSelectedTextRange` cleanly; Chrome needs `AXEnhancedUserInterface=true`; Electron apps need `AXManualAccessibility=true` and *still* return `{loc=0,len=0}` for the caret because Apple treats the cursor API as private; browser `contentEditable` / rich editors and Terminal are unreliable. See [Open questions][oq].
- There is **no public way to invalidate a stale AX element reference** short of restarting the process. `axuielementObject:isValid()` exists but a "valid" element can still silently reject writes. Any design must treat the captured element as best-effort and degrade gracefully.
- `hs.window:focus()` has documented bugs with multi-window / multi-screen apps (focuses the wrong window of the same app). Restoration cannot assume `window:focus()` is exact.
- This must not regress the common case: dictate into a field, *keep it focused*, get the transcript pasted. That path must stay as reliable as it is today.

## Decisions

**D1 — Recommended insertion strategy is (A) refocus-then-paste, with (B) AX-element-refocus layered on top as a best-effort precision step, and (C) AX value injection explicitly rejected as the primary mechanism.**

The three strategies from the brief:

- **(A) Refocus original app/window, then `Cmd+V`.** Simplest. Relies on the caret still sitting where it was when the app regained focus. For native fields and most editors this holds: re-activating an app restores its own internal first-responder and caret. This is the floor we can always fall back to.
- **(B) Capture the exact `AXFocusedUIElement` at Tend, and on restore set focus to that element (`setAttributeValue("AXFocusedUIElement", el)` on the app element, plus `el:setAttributeValue("AXSelectedTextRange", capturedRange)` to re-place the caret), then paste.** More precise — survives the case where the app has multiple fields and naive activation lands in the wrong one. But it is exactly the surface that goes stale and is unsupported on Electron/web.
- **(C) AX value injection — write the transcript directly via `el:setAttributeValue("AXSelectedText", transcript)` or by manipulating `AXValue`.** Avoids the synthetic-keystroke + clipboard dance entirely. Rejected as primary because: it fails outright on Electron (caret always `{0,0}`), on `contentEditable`, and on Terminal; `setAttributeValue` "may decline to accept the value" with no error per the [docs][axuielement-docs]; and it would *replace* `AXValue` wholesale if the field doesn't honour `AXSelectedText`, risking destroying the user's existing text. Too dangerous as the default.

Decision: **layered fallback**, attempted in order, first success wins:

1. **(B-light)** If we captured a valid AX element and range, and the element `isValid()` after refocus, set `AXSelectedTextRange` to the captured caret, then `Cmd+V`.
2. **(A)** Otherwise, re-activate the captured app + raise the captured window, then `Cmd+V` into wherever the caret lands.
3. **(Last resort)** If the app/window is gone, do **not** paste blind. Leave the transcript on the pasteboard and fire an `hs.notify` toast: "transcript ready — paste target lost, text is on your clipboard." See D4.

(C) is kept in a back pocket only for a future per-app allowlist of known-good native targets; not in this plan's default path.

**D2 — Capture a snapshot struct at Tend, persisted at module scope; treat every field as independently nullable.**

At **Tend** (inside `stopRecording`, before any state is torn down), capture into a single table, e.g.:

```lua
--- Snapshot of the insertion target taken at Tend (recording stop). Every
--- field is best-effort and independently nullable — AX reads fail silently
--- on many apps. Restoration degrades through D1's fallback ladder based on
--- which fields survived.
local pasteTarget = {
  app = nil,        -- hs.application (frontmostApplication at Tend)
  window = nil,     -- hs.window (focusedWindow at Tend), for raise on restore
  axElement = nil,  -- hs.axuielement AXFocusedUIElement, may go stale
  axRange = nil,    -- {loc=, len=} from AXSelectedTextRange, may be {0,0}
  capturedAt = nil, -- os.time(), for staleness heuristics / logging
}
```

Capture sketch (runs on the main thread at Tend, which is free):

```lua
--- Capture the current insertion target. Called at Tend. Pure reads; never
--- throws — AX failures leave the corresponding field nil.
--- @return table The pasteTarget snapshot (also stored at module scope).
local function capturePasteTarget()
  local app = hs.application.frontmostApplication()
  local win = hs.window.focusedWindow()
  local axEl, axRange = nil, nil
  local sys = hs.axuielement.systemWideElement()
  if sys then
    axEl = sys:attributeValue("AXFocusedUIElement")
    if axEl then axRange = axEl:attributeValue("AXSelectedTextRange") end
  end
  return { app = app, window = win, axElement = axEl,
           axRange = axRange, capturedAt = os.time() }
end
```

Rationale: capturing at Tend (not paste time) is the whole point — by paste time the frontmost app is whatever the user switched to. `frontmostApplication()` and `focusedWindow()` are cheap and stable handles. The AX element is the fragile part; we capture it but never depend on it.

**D3 — Restoration runs in the `hs.task` completion callback, replacing the current two-line paste.**

The current callback tail is:

```lua
hs.pasteboard.setContents(transcript)
hs.eventtap.keyStroke({"cmd"}, "v", 0)
```

It becomes a call into the new module: `focusPaste.restoreAndPaste(pasteTarget, transcript)`. That function runs D1's ladder. Crucially, after re-activating another app we must **wait for activation to settle before pasting** — app activation is asynchronous. The keystroke cannot fire synchronously on the same tick as `app:activate()`. Sketch:

```lua
--- Restore focus to the captured target and insert the transcript. Runs D1's
--- fallback ladder; clipboard is saved/restored per D4.
--- @param target table The pasteTarget snapshot from capturePasteTarget().
--- @param transcript string Clean transcript text to insert.
local function restoreAndPaste(target, transcript)
  if not target or not target.app then
    return leaveOnClipboard(transcript)  -- nothing to restore to
  end
  target.app:activate()
  if target.window then target.window:raise() end
  -- Activation is async; give the WM a beat before pasting. Tunable, see OQ.
  hs.timer.doAfter(ACTIVATION_SETTLE_S, function()
    pasteInto(target, transcript)
  end)
end
```

`ACTIVATION_SETTLE_S` is a new tunable (default guess ~0.12s); its real value is an open question (see [Open questions][oq]) and should become a config key in `voice-dictate-config.lua` if it proves machine-dependent.

**D4 — Clipboard save/restore wraps every paste path (pulls in the deferred v0.2 item).**

Because paste-back now happens after an arbitrary delay and an app switch, silently overwriting the clipboard is worse than in v0.1 — the user may have copied something *during* transcription. So:

```lua
--- Insert transcript via synthetic paste, preserving the user's clipboard.
local function pasteInto(target, transcript)
  local saved = hs.pasteboard.getContents()  -- may be nil (non-text clip)
  hs.pasteboard.setContents(transcript)
  -- Best-effort precise caret placement (D1 step 1) before the keystroke.
  reapplyCaret(target)
  hs.eventtap.keyStroke({"cmd"}, "v", 0)
  -- Restore after the paste has been consumed. Delay, not synchronous — the
  -- target app reads the pasteboard asynchronously on Cmd+V.
  hs.timer.doAfter(CLIPBOARD_RESTORE_S, function()
    if saved ~= nil then hs.pasteboard.setContents(saved) end
  end)
end
```

Two ordering hazards, both flagged in [Open questions][oq]:

- **Restore-too-early race.** If we restore the clipboard before the target app has actually read it on `Cmd+V`, the wrong text pastes. `CLIPBOARD_RESTORE_S` must be long enough to clear the paste read but short enough that the user doesn't notice their clipboard "flicker." This is a heuristic delay; there is no completion signal for "the app finished reading the pasteboard."
- **Non-text clipboard loss.** `hs.pasteboard.getContents()` returns only the string flavour; images / files / RTF are not round-tripped by this naive save/restore. Saving/restoring the full pasteboard requires `hs.pasteboard.readAllData` / `writeAllData` or pasteboard-item APIs. Decision: v1 of this feature saves/restores **string contents only** and documents the limitation; full-flavour round-trip is a follow-up. This is a deliberate, named scope cut.

**D5 — New sibling module `voice-dictate-focus.lua`; main module stays a thin caller.**

Per conventions § split triggers, focus capture/restore is a new logical concern with its own private helpers. Put it in `hammerspoon/voice-dictate-focus.lua`, exporting:

```lua
local focus = require("voice-dictate-focus")
focus.capture()                       -- returns a pasteTarget snapshot (D2)
focus.restoreAndPaste(target, text)   -- D3 + D4 ladder
```

The main module calls `focus.capture()` at Tend and `focus.restoreAndPaste(...)` in the task callback. This keeps [`voice-dictate.lua`][lua] under the cap and mirrors the existing `voice-dictate-mic.lua` sibling pattern. A new `hammerspoon/README.md` section documents it in the same change (CDE rule A1).

**D6 — Preserve the "stay focused and wait" common case bit-for-bit.**

If the user never switches away, `frontmostApplication()` at paste time equals the captured app, `app:activate()` is a near no-op, and the caret is untouched — behaviour is identical to today plus a clipboard restore. The fallback ladder must be ordered so the simple case never pays for the precise case: if the captured app is still frontmost at paste time, skip the activate/raise/settle delay entirely and paste immediately (fast path). Sketch guard:

```lua
local stillFront = hs.application.frontmostApplication()
if stillFront and target.app and stillFront:pid() == target.app:pid() then
  return pasteInto(target, transcript)  -- fast path, no settle delay
end
```

## Sequence of work

1. **Spec the snapshot contract** — finalize the `pasteTarget` fields and the fallback ladder order. (This plan; settle the open questions that block coding.)
2. **Scaffold `hammerspoon/voice-dictate-focus.lua`** with `@fileoverview`, `local M = {}`, the `pasteTarget` shape, and stubbed `M.capture()` / `M.restoreAndPaste()`. Add its `hammerspoon/README.md` section (CDE, same change).
3. **Implement `M.capture()`** (D2). Manually verify the captured snapshot against a native Cocoa field (TextEdit), VS Code (Electron), a browser text input, and Terminal — log what each yields for `axElement` / `axRange`. This calibrates expectations before restore logic exists.
4. **Implement the fast path (D6)** and strategy (A) refocus-then-paste (D3) with the activation settle delay. Verify cross-app: dictate into TextEdit, switch to a browser mid-transcription, confirm text lands back in TextEdit at the caret.
5. **Implement clipboard save/restore (D4)**, string-only. Verify no clipboard clobber in the common case; verify the restore-timing race with a deliberately slow target.
6. **Layer in (B-light) precise caret replacement** for elements that survive `isValid()` (D1 step 1). Verify it improves the multi-field native case; verify it *silently no-ops* (not errors) on Electron/web.
7. **Implement the last-resort path (D1 step 3)** — target gone → notify + leave on clipboard. Verify by quitting the captured app mid-transcription.
8. **Tune `ACTIVATION_SETTLE_S` and `CLIPBOARD_RESTORE_S`** empirically; promote to `voice-dictate-config.lua` keys if machine-variance demands it.
9. **Update docs** — `hammerspoon/README.md` failure-modes + config tables; note the clipboard string-only limitation.

This work has no pure-function smoke surface (it is all AX + eventtap + window-manager I/O), so per conventions § "Bug fixes — failing test first" and the v0.1 testing strategy, each step above ships with a **manual repro checklist** in the commit body rather than an automated test.

## Cross-doc effects

- [`hammerspoon/README.md`][hs-readme] — add a `voice-dictate-focus.lua` section (API, fallback ladder, per-app caveats); extend the failure-modes list (paste target lost, Electron caret unsupported); add `ACTIVATION_SETTLE_S` / `CLIPBOARD_RESTORE_S` to the configurable-values table if they become config keys (D8).
- [`voice-dictate.lua`][lua] header `@fileoverview` — the paste contract changes from "paste into focused app" to "capture at Tend, restore + paste on completion"; update the public-API/paste description.
- [v0.1 spec][v01-spec] § Paste and § "Out of scope" — the spec says the clipboard is "overwritten without restore (v0.1 trade-off; v0.2 candidate is save/restore)". This plan delivers that v0.2 candidate. The spec stays frozen as historical; this plan is the source of truth for the paste contract going forward.
- `voice-dictate-config.lua` (generated by `install/config.sh` per [2026-05-25-install-ux-bootstrap.md][install-plan]) — *only if* D8's tunables become config keys, install's config writer gains two fields. Flag, do not assume.
- INVENTORY.md and the plans switchboard — new `voice-dictate-focus.lua` file and this plan need entries. **Out of scope for this plan to edit** — the orchestrator owns those switchboards.

## Interaction with in-flight sibling plans

- **[2026-05-26-cursor-loader.md][cursor-loader-plan]** (cursor-as-loader). That plan presumably animates the mouse cursor or an overlay as a transcription progress indicator. Tension: both plans touch "what happens between Tend and paste." If the loader plan moves or warps the *mouse* cursor, it must not disturb the *keyboard* focus / caret this plan captures — mouse position and AX text focus are independent, so they should compose, but the loader must not click or activate anything that changes `frontmostApplication`. Coordinate: the loader is visual-only; this plan owns focus state. Confirm no overlap in who calls `app:activate()`.
- **[2026-05-26-streaming-transcription.md][streaming-plan]** (streaming transcription). **Direct conflict.** Streaming implies *incremental* paste of partial transcripts as whisper emits them; this plan implies a *single deferred* paste-back after the user has possibly switched windows. The two models are mutually exclusive at the paste layer: you cannot stream partial text into a field the user has navigated away from without yanking focus back repeatedly (hostile UX), and you cannot defer a single paste if you are streaming. Resolution must be a product decision, not an engineering one — likely: streaming is only valid in the "stay focused" mode (D6 fast path), and cursor-lock async paste-back disables streaming for that utterance. Whichever plan ships second must name this dependency and pick the mode-arbitration rule. Flagged here; not resolved.

## Risks

- **AX element staleness is the headline risk.** Research confirms there is no cache-invalidation API; a captured `AXFocusedUIElement` can report `isValid()==true` and still reject `setSelectedTextRange`. Mitigation: (B-light) is strictly an *optimisation* on top of (A); a stale element degrades to plain refocus-then-paste, never to a hard failure.
- **Cross-app focus restoration is not guaranteed.** `hs.window:focus()` has known multi-window / multi-screen bugs (focuses the wrong window of the same app), and `app:activate()` does not always restore a window's first-responder. The fast path (D6) sidesteps this for the common case, but genuine cross-app paste-back into a multi-window app is the shakiest scenario. Confidence is moderate, not high.
- **Clipboard restore race.** No signal exists for "the target finished reading the pasteboard on Cmd+V," so restore timing is a tuned guess. Too short → wrong paste; too long → visible clipboard flicker. Worst realistic outcome is the user's clipboard momentarily holds the transcript — recoverable, not destructive.
- **Synthetic `Cmd+V` into the wrong place.** If activation lands focus in an unexpected field (or a dialog grabbed focus), `Cmd+V` injects the transcript somewhere unintended. Mitigation: the last-resort path refuses to paste when the target app/window is gone; but it cannot detect "right app, wrong field." Accept as a known limitation; the (B-light) caret-reapply reduces but does not eliminate it.
- **Electron / browser / Terminal coverage.** For these, `axRange` is `{0,0}` or absent, so only strategy (A) applies and caret precision is whatever the app's own refocus does. For the user's real workload (Greek dictation into chat/editor apps, many of which are Electron), this means "refocus the app and paste at its current caret" — usually fine, occasionally off. Set expectations in the README.
- **Module growth.** [`voice-dictate.lua`][lua] is already at/over the 200-line soft cap; this plan deliberately offloads to a sibling (D5) to avoid breaching the 300-line hard stop. If the focus module itself approaches the cap, split capture vs. restore.

## Open questions

These are unresolved and would materially change the implementation; flagged per conventions § "spec is settled when it has no implicit open questions."

1. **Does setting `AXFocusedUIElement` on the application element reliably move focus back to a specific field across the user's real target apps?** Research confirms the API exists and is fast (~0.38ms to set a range) on native Cocoa, but cross-app reliability for *focus* (not just caret) is unverified. Needs hands-on calibration in step 3.
2. **What is a safe `ACTIVATION_SETTLE_S`?** App activation is async with no completion callback in `hs.application:activate()`. Is there a `hs.application.watcher` (`activated` event) we can await instead of a fixed timer? Preferred if it exists — eliminates a guess. Investigate before settling D3.
3. **What is a safe `CLIPBOARD_RESTORE_S`?** Same shape — is there any pasteboard-changed signal (`hs.pasteboard.watcher` / change count) that tells us the target consumed the paste, so we can restore deterministically instead of on a timer?
4. **Should non-text clipboard flavours be preserved in v1?** D4 cuts this to string-only. If the user routinely has images/files on the clipboard, the cut is more painful than assumed. Confirm with the user before locking D4.
5. **Mode arbitration with streaming** (see sibling-plans section). Unresolved across plans; needs a product decision on whether async paste-back and streaming can coexist per-utterance.
6. **Does the user actually want focus *yanked back* to the original window on completion?** Restoring focus is intrusive if the user has moved on. Alternative UX: don't steal focus — paste only if the captured app is still frontmost, otherwise notify + leave on clipboard. This is arguably *safer* than D1's activate-and-paste and should be offered as a config toggle (`stealFocusOnPaste = true/false`). Needs a product call; it changes the default behaviour materially.

[v01-spec]: 2026-05-20-v0.1-spec.md
[install-plan]: 2026-05-25-install-ux-bootstrap.md
[cursor-loader-plan]: 2026-05-26-cursor-loader.md
[streaming-plan]: 2026-05-26-streaming-transcription.md
[conventions-md]: ../conventions.md
[lua]: ../../hammerspoon/voice-dictate.lua
[hs-readme]: ../../hammerspoon/README.md
[axuielement-docs]: https://www.hammerspoon.org/docs/hs.axuielement.html
[oq]: #open-questions
