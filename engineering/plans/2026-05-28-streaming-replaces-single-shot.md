# 2026-05-28 — Streaming replaces single-shot on the existing hotkeys

Owner: thanpolas. Status: superseding D5 of [the streaming-transcription plan][stream-plan].

Supersedes one decision from the [streaming plan][stream-plan]: D5 ("Opt-in mode: separate hotkey, default unchanged"). That plan kept single-shot as the default and put streaming behind a distinct `Cmd+Shift+S`. In practice the separate hotkey is friction — the user wants streaming behaviour on the same two surfaces they already reach for: Right Option (PTT) and `Cmd+Shift+D` (toggle). Empirical preference, post-implementation, after using the separate-hotkey variant for less than a session.

## What changes

- **Right Option (held)** now starts streaming on press, stops on release. Same hold semantics as before; the underlying pipeline is now [`bin/stream.sh`][stream-sh] + the splice layer, not record-then-transcribe.
- **`Cmd+Shift+D` (tap)** now toggles a streaming session — start on first tap, stop on second tap.
- **`Cmd+Shift+S`** is unbound — it was the opt-in entry point and is no longer needed.
- **Single-shot** ([`bin/dictate.sh`][dictate-sh]) is no longer reachable from any hotkey. The shell entry point stays for manual testing (`./bin/dictate.sh smoke`, ad-hoc transcription of WAVs); the Lua single-shot machinery in [`voice-dictate.lua`][lua] is deleted because it has no remaining caller.

## Why the scope flip

D5 traded liveness for safety — keep the proven path, layer streaming beside it, let the user pick per utterance. The trade was defensible at plan time but cost more than it bought:

- **Cognitive overhead.** Two hotkeys for the same conceptual action (dictate text into the focused field) is one too many.
- **Single-shot wasn't winning utterances.** The accuracy advantage the plan named is real but small for the user's prompt-entry workload; the latency penalty (silence-to-paste lag) is loud. Streaming wins on liveness and is "good enough" on accuracy.
- **`Cmd+Shift+S` collided** with at least one app on this machine and never fired. Diagnosing the conflict is wasted effort against a hotkey that shouldn't exist in this design anyway.

The accuracy-first mandate from the v0.1 spec is **not** discarded — single-shot remains callable via `bin/dictate.sh` for the rare case where accuracy beats liveness (e.g. dictating a code identifier into a WAV for ad-hoc transcription). It just isn't on a hotkey.

## What stays from the original plan

Every architectural decision except D5 carries over:

- D1 — `whisper-stream` step mode + clipboard-mediated splice.
- D2 — Step/length/keep defaults (500/5000/200), commit/tail logic, append-only fallback.
- D3 — Substring divergence skip.
- D4 — Clipboard snapshot/restore on session boundaries.
- D6 — Focus-loss self-stop.

All five remain authoritative. The streaming code itself (`bin/stream.sh`, `voice-dictate-stream.lua`, `voice-dictate-splice.lua`) doesn't change semantically — only the entry-point hotkeys change.

## Code shape after the change

- [`voice-dictate.lua`][lua] — sheds `startRecording`, `stopRecording`, `transcribeAndPaste`, `newWavPath`, `stripAnsi`, the `recording` / `recordTask` / `currentWav` state, and `FLUSH_DELAY_S`. `onToggleTap` and `onFlagsChanged` call into [`voice-dictate-stream-mode`][stream-mode-lua]'s session API directly.
- [`voice-dictate-stream-mode.lua`][stream-mode-lua] — sheds its own hotkey binding and `currentCfg` state. Becomes a thin orchestrator exposing `M.startSession(cfg)`, `M.stopSession()`, `M.isActive()`, plus a one-shot `M.init()` that wires `splice.setOnStop` for the focus-loss self-stop.
- [`voice-dictate-menu.lua`][menu-lua] — drops the transcription spinner (no transcribing phase under streaming), relabels "Recording…" to "Streaming…", and the dropdown's "Start / Stop Dictation" item now drives the streaming toggle.
- [`install/config.sh`][config-sh] — stops writing `stream_toggle_mods` and `stream_toggle_key` to the Lua config; both keys are unused. `stream_sh` and `stream_append_only` stay.

## Out of scope

- No changes to [`bin/stream.sh`][stream-sh], [`bin/dictate.sh`][dictate-sh], the splice mechanic, or any spike findings — D1–D4 + D6 are untouched.
- The step 7 measurement checklist in [the spike log][spike-log] is still authoritative; "go/no-go on flipping `cfg.streaming_default = true`" is now moot because streaming is the *only* path, but the criteria (latency, flicker, accuracy regression, divergence skip, focus-loss stop, clipboard preservation) remain the right qualitative bar.

[stream-plan]: 2026-05-26-streaming-transcription.md
[spike-log]: 2026-05-26-streaming-spike-log.md
[dictate-sh]: ../../bin/dictate.sh
[stream-sh]: ../../bin/stream.sh
[lua]: ../../hammerspoon/voice-dictate.lua
[stream-mode-lua]: ../../hammerspoon/voice-dictate-stream-mode.lua
[menu-lua]: ../../hammerspoon/voice-dictate-menu.lua
[config-sh]: ../../install/config.sh
