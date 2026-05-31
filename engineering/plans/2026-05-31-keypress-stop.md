# 2026-05-31 — Any keystroke stops a streaming session

Owner: thanpolas. Status: settled.

Adds a fourth stop trigger to the streaming state machine: while a session is
active, pressing any ordinary key in the focused field ends the session. This
extends — does not replace — the three existing stop paths (a second toggle tap,
Right Option release, focus loss). It exists because the natural gesture for
"the transcript is good enough, I'll take it from here" is to just start typing;
forcing the user back to `Cmd+Shift+D` to stop first is friction.

## What changes

- **Any ordinary keystroke**, while a session is active, stops the session — the
  same stop as a second toggle tap: the pipeline tears down, the menubar flips to
  finalizing then idle, the pre-session clipboard is restored. Equivalent to
  pressing the toggle again, reachable from the keyboard the user's hands are
  already on.
- A new always-on `keyDown` eventtap in [`voice-dictate.lua`][lua] observes
  keystrokes, mirroring the existing always-on `flagsChanged` PTT tap. Its
  handler is a no-op unless a session is active.

## Decisions

Three product calls, settled with the user on 2026-05-31:

- **D-K1 — Semantics: stop and keep.** The keystroke ends the session and
  **keeps** the transcript already pasted into the field — identical to the
  existing toggle/PTT stop. It does not discard or revert anything. Cancel-and-
  discard was considered and rejected: it adds a splice-revert step and risks
  clobbering the user's own edits, for no clear benefit over just deleting the
  text manually after stopping.
- **D-K2 — Trigger key passes through.** The keystroke that triggers the stop
  reaches the field normally — the tap is observational and returns `false`,
  never swallowing the event. The gesture is "I'm taking over typing now," so
  the first character the user types must land where they expect.
- **D-K3 — Scope: any ordinary key.** Any `keyDown` whose flags carry **no**
  `Cmd`, `Ctrl`, or `Alt` modifier counts. `Shift` alone is allowed (capital
  letters and symbols still stop). Modifier-only presses never produce a
  `keyDown`, so they are inherently excluded.

## Why the no-modifier filter is load-bearing

The splice layer ([`voice-dictate-splice.lua`][splice]) synthesizes keystrokes
into the focused field on every emission: `Shift+Cmd+Up`, `Cmd+X`, `Cmd+V`.
A naive "any keyDown stops" tap would catch **our own** synthetic keystrokes and
self-cancel the instant the first transcript pasted.

Every synthetic splice keystroke carries `Cmd`. So does the toggle combo
(`Cmd+Shift+D`) itself. Defining "ordinary key" as *a keyDown with no
Cmd/Ctrl/Alt modifier* (D-K3) therefore excludes all of them structurally — no
event-marking via `eventSourceUserData`, no source inspection, no allowlist of
keycodes. The filter that implements the product scope is the same filter that
prevents self-cancellation. One rule, both jobs.

## Lifecycle

The tap mirrors `pttTap` exactly: created and started in `bindHotkeys`, stopped
and released in `unbindHotkeys`, so it lives only while the module is mounted and
is torn down on `hs.reload()` with everything else. It stays started across the
idle⇄streaming boundary rather than starting/stopping per session, and the
handler guards on `streamMode.isActive()`.

This is deliberately robust to the focus-loss stop path: focus loss tears down a
session through the splice layer's `onStop` hook, bypassing the main module's
`stopSession`. A per-session start/stop of the tap would leak a started tap after
a focus-loss stop. An always-on tap guarded by `isActive` self-corrects against
every stop path. The cost is one cheap Lua guard per keystroke while mounted —
the same shape and cost as the existing PTT `flagsChanged` tap.

## Out of scope

- No new config key. The behaviour is always on; if a later session wants it
  switchable, that is a new dated plan with an install-written `stop_on_keypress`
  default. Adding the knob now is config surface nobody has asked for.
- No change to the splice mechanic, the pipeline, the menubar, or the install
  scripts.
- Cancel-and-discard semantics (rejected under D-K1) are not implemented.

[lua]: ../../hammerspoon/voice-dictate.lua
[splice]: ../../hammerspoon/voice-dictate-splice.lua
