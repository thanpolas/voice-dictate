# bin — shell side

`dictate.sh` is the record/transcribe entry point spawned by [voice-dictate.lua](../hammerspoon/voice-dictate.lua); standalone-runnable for manual testing. Three sibling scripts provide automated tests and a process watchdog — they are not in the runtime path.

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

## [test-record-shutdown.sh](test-record-shutdown.sh)

End-to-end test of `dictate.sh record` shutdown — reproduces what Hammerspoon does on PTT release without needing a keyboard. Four scenarios: `basic` (2s hold + SIGTERM), `rapid` (SIGTERM ~200ms after spawn), `no-orphans` (5 back-to-back cycles), `wav-duration` (3s hold preserves ≥2s of audio). Run after any change to `dictate.sh`. Override the mic with `AUDIO_DEVICE=:N`.

## [test-transcribe-output.sh](test-transcribe-output.sh)

Regression test against the `(B[m` ANSI prefix that leaked into pasted transcripts. Invokes `dictate.sh transcribe` two ways — directly and via `/bin/bash -c "…"` (Hammerspoon's `hs.execute` shape) — and asserts the output has no `\e` control bytes. Uses the bundled JFK fixture at `/opt/homebrew/share/whisper-cpp/jfk.wav`.

## [monitor-ghosts.sh](monitor-ghosts.sh)

Background watchdog that polls `pgrep` every 0.5s for `ffmpeg.*voice-dictate` and logs START/WAV/GONE transitions to `/tmp/voice-dictate-ghost-watch.log`. Designed to catch orphan ffmpegs in the wild during long dictation sessions — complementary to `test-record-shutdown.sh`'s automated coverage. Subcommands: `start | stop | status | tail | reset`.
