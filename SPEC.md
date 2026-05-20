# voice-dictate — Spec

Local hotkey-driven speech-to-text dictation for macOS, using [whisper.cpp][whisper-cpp] and [Hammerspoon][hammerspoon]. Privacy-first: no audio leaves the machine.

---

## Problem

The default macOS dictation is mediocre for Greek and cannot mix Greek with English technical terms. Cloud services (Wispr Flow, SuperWhisper) cost monthly fees and send audio off-device. The user already has whisper.cpp installed locally with Greek models. The missing piece is a global hotkey UX that ties recording, transcription, and pasting into a one-keypress flow.

---

<a id="goals-anchor"></a>

## Goals

- Press a hotkey, speak, release/toggle — transcript appears in the focused text field.
- 100% local. No network calls.
- Latency: accuracy-first. Up to ~5 seconds from speech end to pasted text is acceptable. Real-time streaming is not a goal.
- Greek-first; English handled by Whisper's multilingual model at the same hotkey (no language switch needed for code-switching in v0.1 — see [Open questions][open-questions-anchor]).

## Non-goals (v0.1)

- LLM post-processing / cleanup layer.
- Custom vocabulary / prompt biasing.
- Visual overlay (canvas window with waveform). Menubar text + audio cues only.
- English-dedicated hotkey. Whisper auto-detects within the Greek model run; if accuracy is bad for English we add a dedicated hotkey in v0.2.
- Streaming / partial transcription. Record-then-transcribe is fine for utterances under ~30s.
- Multi-user / configurable model paths via UI. Model path is a constant in the shell script; edit-the-file is the configuration UX.

---

## Scope — what ships in v0.1

| Capability | Behavior |
|------------|----------|
| **Push-to-talk** | Hold `Right Option` → records while held → on release, transcribe and paste. |
| **Toggle** | Tap `Cmd+Shift+D` to start, tap again to stop, then transcribe and paste. |
| **Audio cues** | Distinct system sound on start and on stop. No silence-detection beep. |
| **Menubar indicator** | Text changes to `● REC` while recording, blank otherwise. |
| **Output mechanism** | Copy to clipboard, simulate `Cmd+V` into focused app. |
| **Failure UX** | Hammerspoon notification with stderr tail when transcription fails. |

---

## Constraints

- macOS only (`darwin`). Hammerspoon is Mac-exclusive; no cross-platform.
- Apple Silicon assumed (M-series). whisper.cpp on Intel works but is much slower; not a v0.1 concern.
- Greek + English bilingual user. The default Whisper run uses `-l el`; English utterances in that mode degrade but remain usable. See [Open questions][open-questions-anchor].
- Lua + POSIX shell only. No Python runtime, no Node, no Homebrew formula authoring. Hammerspoon Lua VM + `/bin/bash` is the entire runtime surface.
- Reuse the user's existing whisper.cpp install and models. Do not download or build anything at install time.

---

## Architecture

Two processes, glued by Hammerspoon:

```
┌─────────────────────┐
│   Hammerspoon Lua   │  hotkey handlers, state machine, paste
│   (init.lua)        │
└──────────┬──────────┘
           │ spawns
           ▼
┌─────────────────────┐
│   dictate.sh        │  ffmpeg record → whisper-cli → stdout
│   (POSIX bash)      │
└─────────────────────┘
```

### Boundary: Lua ↔ shell

- **Lua starts recording** by spawning `dictate.sh record <wav-path>` as a background process and stashing the PID.
- **Lua stops recording** by sending `SIGINT` to the PID. `ffmpeg` flushes the WAV cleanly on `SIGINT`.
- **Lua transcribes** by running `dictate.sh transcribe <wav-path>` synchronously. Stdout is the plaintext transcript.
- **Lua pastes** by writing transcript to clipboard via `hs.pasteboard.setContents()` and firing `Cmd+V` via `hs.eventtap.keyStroke()`.

### State machine (toggle mode)

```
IDLE ──tap──► RECORDING ──tap──► TRANSCRIBING ──done──► IDLE
                 │                                        ▲
                 └─────── PTT release ────────────────────┘
```

PTT and toggle share one state variable — pressing the toggle hotkey while PTT-recording is undefined behavior (last writer wins). Acceptable in v0.1.

### Audio capture

- `ffmpeg -f avfoundation -i ":0"` — index `:0` is the default microphone on macOS.
- Output: 16 kHz mono PCM WAV → `/tmp/voice-dictate-<unix-ts>.wav`.
- ffmpeg handles `SIGINT` by flushing and exiting 0 (verified behavior of recent ffmpeg builds).

### Transcription

- `whisper-cli -m <model> -f <wav> -l el -t 8 -nt` — `-nt` strips timestamps from output, giving plain transcript on stdout.
- Model: `~/tiktok/whisper-models/ggml-large-v3-turbo-q5_0.bin` (quantized large-v3-turbo, ~547MB). Selected for accuracy-first dictation — ~5% Greek WER, handles English code-switching well, ~5x realtime on M-series. Turbo drops translation capability vs full `large-v3` but matches it on transcription accuracy at one-third the compute. Swap path is a one-line edit to `dictate.sh`.

### Paste

- `hs.pasteboard.setContents(transcript)` then `hs.eventtap.keyStroke({"cmd"}, "v", 0)`.
- The user's clipboard is overwritten without restore. v0.1 trade-off; v0.2 candidate is save/restore around paste.

---

## File layout

```
voice-dictate/
├── README.md                # root switchboard
├── SPEC.md                  # this file
├── PLAN.md                  # implementation order
├── INSTALL.md               # one-shot install + permissions walkthrough
├── bin/
│   ├── README.md            # shell scripts — purpose, contracts
│   └── dictate.sh           # record / transcribe entry point
├── hammerspoon/
│   ├── README.md            # Lua module — exports, hotkeys
│   └── voice-dictate.lua    # loadable from user's init.lua
└── install.sh               # symlinks hammerspoon/voice-dictate.lua into ~/.hammerspoon and wires loader
```

`install.sh` is idempotent: re-running it overwrites the symlink and reloads Hammerspoon config.

---

## Configuration surface

All tunable values live as named constants at the top of their respective files. No config file in v0.1.

| Constant | File | Default | Why |
|----------|------|---------|-----|
| `MODEL_PATH` | `bin/dictate.sh` | `~/tiktok/whisper-models/ggml-large-v3-turbo-q5_0.bin` | Accuracy-first; ~5% Greek WER. |
| `LANGUAGE` | `bin/dictate.sh` | `el` | Greek primary. |
| `THREADS` | `bin/dictate.sh` | `8` | Matches user's existing `transcribe()` function. |
| `AUDIO_DEVICE` | `bin/dictate.sh` | `:0` | macOS default mic. |
| `PTT_HOTKEY` | `hammerspoon/voice-dictate.lua` | `rightAlt` (Right Option) | Universal modifier, non-conflicting. |
| `TOGGLE_HOTKEY` | `hammerspoon/voice-dictate.lua` | `cmd+shift+D` | Mnemonic (D = dictate). |

---

## Dependencies — pre-existing

Hard requirements; install script verifies presence and aborts if missing.

- [whisper.cpp][whisper-cpp] CLI (`whisper-cli` on `$PATH`)
- [Hammerspoon][hammerspoon] (`/Applications/Hammerspoon.app`)
- [ffmpeg][ffmpeg] (`ffmpeg` on `$PATH`)
- Whisper model at `MODEL_PATH`

The install script does not install these — it validates them.

---

## Permissions

macOS will prompt the first time Hammerspoon needs each. Documented in `INSTALL.md`:

- **Accessibility** — required for `hs.eventtap.keyStroke` (the paste).
- **Microphone** — required for `ffmpeg` (spawned by Hammerspoon, inherits TCC scope).
- **Input Monitoring** — may be needed for global hotkey capture depending on macOS version.

---

## Testing strategy

This is a Lua + shell tool with audio I/O and OS-level hotkeys. Arrivance's A4 (test-driven) applies to pure-function code; the testable surface here is narrow:

| Layer | Testability | v0.1 approach |
|-------|-------------|---------------|
| `dictate.sh transcribe <wav>` | High — pure function over an input WAV | Smoke test: transcribe the bundled JFK fixture at `/opt/homebrew/share/whisper-cpp/jfk.wav`, assert non-empty output containing expected tokens. |
| `dictate.sh record` | Medium — needs mic | Manual: record 3s, inspect WAV header with `file`. |
| Hammerspoon Lua | Low — embedded VM, no headless test runner | Manual: hotkey → recording starts, hotkey → text appears. |

A4 here means: the shell transcribe path has a smoke test in `bin/test-transcribe.sh` invoked manually. We do not pretend to unit-test the audio pipeline.

---

## Out of scope, named explicitly

To prevent scope creep — these are deferred to v0.2+, not silently dropped:

- LLM cleanup layer (punctuation, disfluency removal).
- Custom vocabulary (`whisper-cli --prompt`).
- Dedicated English hotkey.
- Visual feedback overlay.
- Clipboard save/restore around paste.
- Streaming / partial transcription.
- Config file (`~/.config/voice-dictate.toml`).
- Per-app behavior (e.g., different language for Slack vs VS Code).

---

## Open questions

<a id="open-questions-anchor"></a>

1. **Code-switching quality.** Whisper at `-l el` handles English words but quality degrades on long English passages. Decision deferred to first week of use; if painful, add `Cmd+Shift+E` as English-dedicated PTT.
2. **Toggle hotkey conflict.** `Cmd+Shift+D` is used by some apps (e.g., Slack: "do not disturb"). If it clashes in practice, fall back to `Cmd+Shift+;` or a hyper-key.
3. **Long-utterance latency.** large-v3-turbo-q5_0 runs at ~5x realtime, so a 60s utterance takes ~12s to transcribe. Acceptable per [Goals][goals-anchor] but worth measuring on real workload. If routine and painful, evaluate `large-v3-turbo` (fp16) for marginal speed gain via Metal kernel paths.

---

## Changelog

- **2026-05-20 — v0.1 spec drafted.** Scope locked to record/transcribe/paste with two hotkeys. Model: `large-v3-turbo-q5_0`. Latency target relaxed to ≤5s for accuracy.

[whisper-cpp]: https://github.com/ggerganov/whisper.cpp
[hammerspoon]: https://www.hammerspoon.org/
[ffmpeg]: https://ffmpeg.org/
[open-questions-anchor]: #open-questions
