# bin — shell side

Single script, three subcommands. Spawned by [voice-dictate.lua](../hammerspoon/voice-dictate.lua) but standalone-runnable for testing.

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

### Configurable constants

All four are environment-overridable (`VAR=x dictate.sh ...`) and then locked readonly inside the script:

| Constant | Default | Purpose |
|----------|---------|---------|
| `MODEL_PATH` | `~/tiktok/whisper-models/ggml-large-v3-turbo-q5_0.bin` | The Whisper checkpoint. Swap to medium / large variants here. |
| `LANGUAGE` | `el` | Whisper `-l` flag. Use `auto` for detection, `en` for English-only. |
| `THREADS` | `8` | whisper-cli `-t` flag. Match physical core count. |
| `AUDIO_DEVICE` | `:0` | ffmpeg avfoundation device spec. List devices with `ffmpeg -f avfoundation -list_devices true -i ""`. |

### Changing the model

One-line edit at the top of [dictate.sh](dictate.sh), or override per-invocation:

```bash
MODEL_PATH=~/tiktok/whisper-models/ggml-medium-q5_0.bin dictate.sh smoke
```

### PATH handling

The script prepends `/opt/homebrew/bin` to PATH at startup because Hammerspoon-spawned tasks inherit a minimal environment without it. If you move Homebrew off `/opt/homebrew`, update the export at the top.

### Size budget

Soft cap 200 lines, currently ~100. Split triggers: a fourth subcommand, or a new pre/post-processing layer (e.g. LLM cleanup) that doesn't belong inline in `transcribe`.
