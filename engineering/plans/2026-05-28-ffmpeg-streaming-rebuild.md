# 2026-05-28 — Streaming rebuilt on ffmpeg + whisper-server

Owner: thanpolas. Status: in progress. Supersedes [D1 of the streaming plan][stream-plan] (whisper-stream + SDL2 capture) and adjusts the [supersession plan's][supersedes-plan] architecture; D3, D4, D6 still apply.

## Why scrap whisper-stream

Real-session testing proved out a hard problem: `whisper-stream` captures via SDL2's CoreAudio path, which **bypasses macOS's Voice Processing IO unit** (AGC, noise suppression, echo cancellation). The iMac internal mic produces raw audio that needs that DSP to be ASR-grade — without it, whisper hallucinates training-data patterns regardless of model, window length, or capture device. Same physical mic captured via ffmpeg's AVFoundation path applies Voice Processing automatically and produces perfect transcripts.

The diagnostic that settled it ([journey log on the supersession plan][supersedes-plan]):

| Capture stack | Transcript |
|---|---|
| iMac mic + ffmpeg | "Δοκιμή 1,2,3 Πρώτη πρόταση, δεύτερη πρόταση" — perfect |
| iMac mic + whisper-stream/SDL2 | "Υπότιτλοι AUTHORWAVE Μην είναι ένα πρόταση" — hallucination |

Same WAV format on disk, same model, same language. The capture is the variable.

## Constraints

- AVFoundation (ffmpeg) for capture — no exceptions. This is the core lesson.
- No new runtime dependencies. Everything ships with `brew install whisper-cpp` already (`whisper-server` and `whisper-cli` are both present).
- The existing single-shot path in [`bin/dictate.sh`][dictate-sh] is untouched and still ships. The mic picker, hotkeys, splice/append paste layer — all carry over.
- 200-line soft cap per source file. Split eagerly.

## Architecture

Three processes glued by Hammerspoon:

1. **`ffmpeg`** — continuous recording from AVFoundation to a session-scoped WAV. Same flags as [`bin/dictate.sh record`][dictate-sh]; literally the same capture call.
2. **`whisper-server`** — HTTP daemon, model loaded once. Receives audio chunks via POST, returns transcripts. Persistent across the session, killed on `M.stop()`.
3. **Hammerspoon timer** — every ~2s, posts the latest audio chunk from the WAV to the server, gets the transcript, computes the new-content delta vs the previous post, dispatches the delta to the existing splice/append paste layer.

The splice layer ([`voice-dictate-splice.lua`][splice-lua]) doesn't change — it still receives emission strings and pastes them. The orchestrator just changes how emissions are produced.

## Sequence of work

One atomic commit per step.

### Step 1 — ffmpeg recording in the streaming path

Replace `bin/stream.sh`'s `exec whisper-stream` call with the same ffmpeg invocation [`bin/dictate.sh record`][dictate-sh] uses. The script now takes a WAV path argument (the orchestrator decides where), starts recording, and runs until SIGTERM/SIGINT — identical lifecycle to `dictate.sh record`. No transcription happens in this step; the WAV just accumulates on disk. Verification: run from a terminal, speak, Ctrl-C, transcribe the WAV with `bin/dictate.sh transcribe` — expect the same clean output as the AVFoundation diagnostic above.

### Step 2 — whisper-server daemon bootstrap

A tiny shell helper (`bin/stream-server.sh` or similar) that starts `whisper-server` on a loopback port with the configured model + language, prints the PID, and a sibling `stop` subcommand that kills it. Verify with `curl -F 'file=@some.wav' http://127.0.0.1:PORT/inference` and check that the response contains the expected transcript. Whisper-server warmup is one-time per session — subsequent requests use the already-loaded model.

### Step 3 — Lua orchestrator: timer-driven server calls + delta paste

Replace `voice-dictate-stream.lua`'s `hs.task` on `whisper-stream` with: launch ffmpeg via the step-1 script, launch the server via the step-2 script, then start an `hs.timer.doEvery` that POSTs the latest audio chunk to the server, parses the response, computes the new-content delta vs the previous response, and hands the delta to `splice.applyEmission(...)`. Focus-loss self-stop (D6) and clipboard preservation (D4) still apply — wiring carries over from the splice layer.

The delta-compute heuristic: the server returns the full transcript of the entire WAV so far. The previous post returned a transcript of slightly less audio. The new content is the *suffix* of the new transcript that wasn't in the old one. Simplest workable approach: find the longest common prefix; the rest of the new transcript is the delta. Handles the case where whisper revises a word from prior iteration (the common prefix gets shorter, the delta covers the change).

### Step 4 — Cleanup: kill whisper-stream + SDL2 references

Delete the old `whisper-stream` invocation in `bin/stream.sh`. Remove SDL2 device documentation from README, INVENTORY, and config. The `STREAM_CAPTURE_ID` config key goes; audio capture now reuses the existing `AUDIO_DEVICE` (AVFoundation index) — one device picker for both paths. Update [`bin/README.md`][bin-readme] and [`hammerspoon/README.md`][hs-readme] to describe the new pipeline.

## Trade-offs and open questions

- **Inference cadence.** whisper-cli on a growing audio buffer at every iteration is more work than whisper-stream's incremental window. With `large-v3-turbo` and 2-second intervals on M1, expect ~500ms inference for short audio, climbing as the buffer grows. Mitigation: the server can be hit with audio chunks rather than the full file — POST the last N seconds only and rely on `--prompt` for left context. Decision deferred to step 3.
- **Delta heuristic edge cases.** Common-prefix diff loses information when whisper genuinely revises mid-prefix (rare but happens). Acceptable for v1; revisit if it bites.
- **Lifecycle race.** ffmpeg + server + timer all need to start cleanly and stop cleanly together. Idempotent start/stop on each, orchestrator owns ordering. Same shape as today's `streamMode.startSession` / `stopSession`.
- **Disk usage.** ffmpeg writes continuously; long sessions accumulate. Per-session WAVs go to `/tmp` and get cleaned on session end. Same pattern as today's `dictate.sh record`.

[stream-plan]: 2026-05-26-streaming-transcription.md
[supersedes-plan]: 2026-05-28-streaming-replaces-single-shot.md
[dictate-sh]: ../../bin/dictate.sh
[splice-lua]: ../../hammerspoon/voice-dictate-splice.lua
[bin-readme]: ../../bin/README.md
[hs-readme]: ../../hammerspoon/README.md
