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

## Journey log

Running log of what was found in real-session testing and what changed in response. Newest entries at the bottom. The point is to make later sessions cheap to onboard — each entry pairs a symptom with the fix that addressed it.

### 2026-05-28 ~21:15 — Cmd+Shift+S never fired

First test of the original plan's D5 (separate `Cmd+Shift+S` hotkey). PTT still drove single-shot; the new hotkey did nothing. Hammerspoon Console had no error, the bind itself probably succeeded but some other global hotkey owns that chord on this machine.

**Decision:** abandon D5. This plan was opened in response — streaming takes over Right Option + Cmd+Shift+D; Cmd+Shift+S is unbound.

### 2026-05-28 ~21:34 — First splice attempt: ANSI leak + pattern crash

After the rewire, first real session against Claude Code's input. Two cascading bugs:

1. **Shift+Cmd+Up on an empty prompt loaded the previous history entry** instead of selecting nothing. Splice was running the select-cut chain before any text had been pasted. Fix: skip the select-cut on the first emission of a session ([`voice-dictate-splice.lua`][splice-lua] `spliceCycle`).
2. **`malformed pattern (missing ']')` from `cut:gsub(lastPastedDictationText, ...)`.** Whisper-stream renders its stdout in-place with CSI escapes (`\e[2K` to clear-line, etc.); the ESC byte is invisible in the Console but the `[2K` payload leaked into emissions and became the anchor substring on a later cycle. Lua's gsub interprets `[` as the start of a character class. Fixes: reinstate `stripAnsi` in [`voice-dictate-stream.lua`][stream-lua]'s `cleanEmission` (function had been deleted with the single-shot Lua); switch the splice replace from `gsub` to `find(plain=true)` + sub-based concat so pattern magic in the anchor can never reach a pattern matcher.

Also added per-line `[vd-stream] emit:` / `skip:` console traces so the diagnostic loop is "open the Console, see what whisper actually said" instead of guessing.

### 2026-05-28 ~21:40 — Splice loses content; switching to append-only

With ANSI fixed and traces on, the field showed only the *last* emission's text — everything spoken earlier was gone. whisper-stream's step-mode emissions over a 5s window with `ggml-large-v3` + Greek are not stable revisions; successive emissions are largely-disjoint transcripts of overlapping audio, and the splice happily replaced each with the next. The last emission was itself a hallucination ("Υπότιτλοι AUTHORWAVE" = whisper falling back to subtitle-training-data patterns when context is thin).

**Decision:** flip the default to the [Spike 1 append-only fallback][stream-plan]. `appendCycle` now inserts a space between emissions; `stream_append_only = true` becomes the install-written default; existing configs that explicitly set `false` are respected.

### 2026-05-28 ~21:40 — Append works; transcription quality is bad regardless

With append-only on, every real emission lands in the field — confirmed via Console traces. Problem: the *content* of those emissions is mostly hallucination. ~10% of words spoken in Greek made it through correctly. 5s windows with `ggml-large-v3` + Greek + no `--prompt` priming = whisper falling back to "common-sounding" Greek tokens unrelated to the input.

**Lever 1 (not taken yet):** bump `STREAM_LENGTH_MS` from 5000 to 10000 — more context per emission. Cost: slower per-emission inference, less "live" feel.

**Lever 2 (taken):** switch the model from `ggml-large-v3.bin` (3.0 GB, slow) to `ggml-large-v3-turbo-q5_0.bin` (547 MB, 2-3× faster on M1, comparable quality). The turbo file was already on disk at `~/whisper-models/`. Edited `bin/config.local.sh`'s `MODEL_PATH` to point at it. `hs.reload()` picks it up since dictate.sh sources the local config on every spawn.

### 2026-05-28 ~21:47 — Turbo cuts latency; quality still bad at 5s

Post-turbo session: emissions arrive every ~2s (was 3-5s with large-v3 — confirms ~2× speedup). Field still mostly hallucinations though: "Υπότιτλοι AUTHORWAVE" appeared as the very first emission, then four near-identical riffs on "Για να δούμε τα πώς…" ("Let's see how…") — whisper anchoring on a comfortable Greek phrase pattern rather than the actual audio. 5s window remains too thin.

**Lever 1 (taken):** bump `STREAM_LENGTH_MS` default from 5000 to 10000 in [`bin/stream.sh`][stream-sh]. Turbo's per-emission inference at 10s is roughly the same wallclock as large-v3 at 5s was, so live-feel doesn't degrade. `bin/README.md`'s config table updated to match.

### 2026-05-28 ~21:55 — Wrong mic: SDL2 default was BlackHole 2ch

With turbo + 10s the quality was still mostly hallucinations ("Ωραία! Ωραία! Ωραία!" repeating; "Αυτή. αυτή η θέα θα σώσω πιο" loops; the recurring "Υπότιτλοι AUTHORWAVE" subtitle artifact). That artifact is the smoking gun — whisper emits it when it hears silence or unrelated noise and falls back to common training patterns.

Running `./bin/stream.sh stream` from a terminal exposed why. SDL2's device enumeration on this Mac:

```
init: found 4 capture devices:
init:    - Capture device #0: 'External Audio Device'
init:    - Capture device #1: 'iPhone Microphone'
init:    - Capture device #2: 'BlackHole 2ch'
init:    - Capture device #3: 'iMac Microphone'
init: attempt to open default capture device ...
init: obtained spec for input device (SDL Id = 2):
```

`-1` (whisper-stream's "use SDL2 default") resolved to **device #2: BlackHole 2ch** — a virtual loopback that captures desktop audio, not the mic. Every previous session, whisper was transcribing system silence and whatever audio was playing on the Mac. avfoundation's default (used by ffmpeg for the single-shot path) was always the right mic; SDL2 enumerates independently and picked the loopback.

**Decision:** set `STREAM_CAPTURE_ID=3` in `bin/config.local.sh` to pin whisper-stream to device #3 `iMac Microphone` — the user's actual input. (Initially mis-pinned to #1 `iPhone Microphone` based on the name reading like a personal device; user corrected — that one is an older Bluetooth headset that isn't in use.) The config file is gitignored and user-specific, which is the right home — SDL2 device ordering is per-machine. Long-term follow-up: `install.sh` should list SDL2 devices and prompt for the capture ID, the same way it does for ffmpeg's `AUDIO_DEVICE` via the menubar picker; out of scope for this session.

## Test fixture for repeatable comparisons

For meaningful before/after testing across config changes, read the same Greek text aloud each time. Same words, same pace, same mic position — that way an emission table actually shows whether the change helped.

```
Δοκιμή ένα, δύο, τρία. Πρώτη πρόταση, δεύτερη πρόταση. Τέλος δοκιμής.
```

~5 seconds at normal pace. Picked these properties on purpose:

- "ένα, δύο, τρία" are unambiguous numerals — if whisper mangles those, audio quality / mic / model is the bottleneck, not Greek phonetic ambiguity.
- "Πρώτη / δεύτερη πρόταση" gives an ordered token pair — easy to spot in the emission log and tells us if window-overlap dedup is working when it lands twice.
- "Τέλος δοκιμής" closes deterministically — useful for confirming the session captured the tail.
- Short enough to repeat 5-10 times in a row without losing patience or going off-script.

[stream-plan]: 2026-05-26-streaming-transcription.md
[spike-log]: 2026-05-26-streaming-spike-log.md
[dictate-sh]: ../../bin/dictate.sh
[stream-sh]: ../../bin/stream.sh
[lua]: ../../hammerspoon/voice-dictate.lua
[stream-mode-lua]: ../../hammerspoon/voice-dictate-stream-mode.lua
[menu-lua]: ../../hammerspoon/voice-dictate-menu.lua
[splice-lua]: ../../hammerspoon/voice-dictate-splice.lua
[stream-lua]: ../../hammerspoon/voice-dictate-stream.lua
[config-sh]: ../../install/config.sh
