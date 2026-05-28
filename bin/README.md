# bin — shell side

`dictate.sh` is the single-shot record/transcribe entry point spawned by [voice-dictate.lua](../hammerspoon/voice-dictate.lua); standalone-runnable for manual testing. `stream.sh` is its opt-in streaming sibling — long-lived `whisper-stream`, revisable hypotheses, clipboard-mediated splice (see [the streaming-transcription plan](../engineering/plans/2026-05-26-streaming-transcription.md)). Three more sibling scripts provide automated tests and a process watchdog — they are not in the runtime path.

## [dictate.sh](dictate.sh)

```
dictate.sh record <wav-path>       capture mic to WAV until SIGTERM/SIGINT
dictate.sh transcribe <wav-path>   run whisper-cli; print plain transcript to stdout
dictate.sh smoke                   transcribe bundled JFK fixture; assert non-empty
```

### Contracts

- **`record`** — calls `ffmpeg -f avfoundation -i :0` at 16 kHz mono PCM. `exec`s ffmpeg so the parent (Hammerspoon's `hs.task`) can `terminate()` it directly. ffmpeg flushes the WAV trailer on SIGTERM and exits 0.
- **`transcribe`** — calls `whisper-cli -nt -np` (no timestamps, no progress prints). Output is post-processed: newlines → spaces, whitespace collapsed, ends trimmed. Result is one paste-ready line on stdout. Stderr is suppressed; errors surface through exit code only.
- **`smoke`** — uses `/opt/homebrew/share/whisper-cpp/jfk.wav` (the fixture brew installs alongside whisper-cpp). For meaningful assertion, run as `LANGUAGE=en dictate.sh smoke`.

### Configurable values

All four runtime values are sourced from a sibling `config.local.sh` (gitignored, written by `install.sh`) and then locked readonly inside the script. Per-invocation env overrides still work — `config.local.sh` uses the `: "${VAR:=…}"` default form, so a pre-set env value wins.

| Variable | Default | Purpose |
|----------|---------|---------|
| `MODEL_PATH` | prompted at install (`~/whisper-models/ggml-large-v3-turbo-q5_0.bin`) | The Whisper checkpoint. Swap to medium / large variants here. |
| `LANGUAGE` | `el` (prompted) | Whisper `-l` flag. Use `auto` for detection, `en` for English-only. |
| `THREADS` | `8` | whisper-cli `-t` flag. Match physical core count. |
| `AUDIO_DEVICE` | `:0` | ffmpeg avfoundation device spec. List devices with `ffmpeg -f avfoundation -list_devices true -i ""`. |

### Changing the model

Edit `config.local.sh`, or override per-invocation:

```bash
MODEL_PATH=~/whisper-models/ggml-medium-q5_0.bin ./dictate.sh smoke
```

Re-running `../install.sh` is another way — it prompts with your current value as the default.

### PATH handling

The script prepends `/opt/homebrew/bin` to PATH at startup because Hammerspoon-spawned tasks inherit a minimal environment without it. If you move Homebrew off `/opt/homebrew`, update the export at the top.

### Size budget

Soft cap 200 lines, currently ~100. Split triggers: a fourth subcommand, or a new pre/post-processing layer (e.g. LLM cleanup) that doesn't belong inline in `transcribe`.

## [stream.sh](stream.sh)

```
stream.sh stream                    launch whisper-stream; emit lines on stdout until killed
```

Sibling of [dictate.sh](dictate.sh) — single-shot is unchanged. Streaming is opt-in: the user picks per utterance (accuracy → single-shot; liveness → streaming). The two never share state.

### Contracts

- **`stream`** — `exec`s `whisper-stream` in step mode. Emits the current transcription of the rolling audio window every `STREAM_STEP_MS` to stdout. Window length is `STREAM_LENGTH_MS`; `STREAM_KEEP_MS` of the previous window is carried across boundaries. Same model and language the single-shot path uses. `exec` means SIGTERM from Hammerspoon hits whisper-stream directly — no wrapper bash, no avfoundation signal-latency dance: SDL2 cleans up on process exit, no WAV trailer to flush.
- **No subcommand selects single-shot.** That lives in [dictate.sh](dictate.sh). `stream.sh` does one thing.

### Target-field scope

Plain-text fields only — prompt boxes, search bars, single-line and plain-textarea inputs, Terminal prompts. Rich-text editors (Slack, Gmail, Notion, iMessage) are out of scope by design: the splice's `Cmd+X` on styled content yields RTF/HTML the layer cannot reliably modify. The Hammerspoon side enforces the blocklist; this script does no app inspection itself.

### Accuracy caveat

Streaming runs whisper over a sliding 5s window. Single-pass `whisper-cli` on a full utterance — what [dictate.sh](dictate.sh) does — is more accurate, especially at clause boundaries and for technical vocabulary. The streaming defaults trade accuracy for liveness; the user opts in per utterance when liveness matters.

### Configurable values

| Variable | Default | Purpose |
|----------|---------|---------|
| `MODEL_PATH` | from `config.local.sh` | Shared with [dictate.sh](dictate.sh). |
| `LANGUAGE` | from `config.local.sh` | Shared with [dictate.sh](dictate.sh). |
| `THREADS` | from `config.local.sh` | Shared with [dictate.sh](dictate.sh). |
| `STREAM_STEP_MS` | `500` | How often whisper-stream emits the current transcript of the rolling window. Raise to 1000–1500 if splice flicker or inference latency is excessive. |
| `STREAM_LENGTH_MS` | `5000` | Length of the rolling audio window. Raise toward 8000 if 5s drops the start of long thoughts. |
| `STREAM_KEEP_MS` | `200` | Carry-over from the prior window for boundary continuity. Rarely needs tuning. |
| `STREAM_CAPTURE_ID` | `-1` (SDL2 default) | SDL2 capture device ID. **Not** the same as ffmpeg's `MIC_INDEX`; list devices by running `stream.sh` once and watching the SDL2 stderr output. |

### Lifecycle

`stream.sh stream` exits on SIGTERM/SIGINT immediately — whisper-stream is replaced via `exec`, so the kernel delivers the signal to it without a bash intermediary. There is no SIGTERM-graceful-WAV-flush dependency to preserve.

### Size budget

Soft cap 200 lines, currently ~110. Split triggers: per-emission post-processing (filtering hallucinated `[BLANK_AUDIO]` markers, locale normalisation), or an alternate streaming backend (VAD-mode for the rejected-shape-B-vad path).

## [test-record-shutdown.sh](test-record-shutdown.sh)

End-to-end test of `dictate.sh record` shutdown — reproduces what Hammerspoon does on PTT release without needing a keyboard. Four scenarios: `basic` (2s hold + SIGTERM), `rapid` (SIGTERM ~200ms after spawn), `no-orphans` (5 back-to-back cycles), `wav-duration` (3s hold preserves ≥2s of audio). Run after any change to `dictate.sh`. Override the mic with `AUDIO_DEVICE=:N`.

## [test-transcribe-output.sh](test-transcribe-output.sh)

Regression test against the `(B[m` ANSI prefix that leaked into pasted transcripts. Invokes `dictate.sh transcribe` two ways — directly and via `/bin/bash -c "…"` (Hammerspoon's `hs.execute` shape) — and asserts the output has no `\e` control bytes. Uses the bundled JFK fixture at `/opt/homebrew/share/whisper-cpp/jfk.wav`.

## [monitor-ghosts.sh](monitor-ghosts.sh)

Background watchdog that polls `pgrep` every 0.5s for `ffmpeg.*voice-dictate` and logs START/WAV/GONE transitions to `/tmp/voice-dictate-ghost-watch.log`. Designed to catch orphan ffmpegs in the wild during long dictation sessions — complementary to `test-record-shutdown.sh`'s automated coverage. Subcommands: `start | stop | status | tail | reset`.
