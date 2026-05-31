# bin — shell side

`dictate.sh` is the single-shot record/transcribe entry point — kept for ad-hoc shell use; no hotkey reaches it any more. `stream.sh` and `stream-server.sh` together drive the live-streaming pipeline that the Hammerspoon hotkeys now invoke (see [the ffmpeg-streaming-rebuild plan](../engineering/plans/2026-05-28-ffmpeg-streaming-rebuild.md)): `stream.sh record` keeps an `ffmpeg` AVFoundation capture writing to a session WAV; `stream-server.sh` keeps a `whisper-server` daemon loaded so per-tick inference pays no model-load tax; the Lua side polls every ~2s and POSTs a finalised snapshot of the WAV to the daemon. Three more sibling scripts provide automated tests and a process watchdog — they are not in the runtime path.

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
stream.sh record <wav-path>         capture mic to WAV until SIGTERM/SIGINT
```

Sibling of [dictate.sh](dictate.sh)'s `record` subcommand — same `ffmpeg -f avfoundation` flags, same SIGINT-forwarding bash wrapper, same `AUDIO_DEVICE` source. The Hammerspoon side spawns it once per session and signals via SIGTERM when the user stops; ffmpeg flushes the WAV trailer and exits 0. Per-tick transcription lives in [stream-server.sh](stream-server.sh); this script only records.

### Why a separate script

`dictate.sh record` already produces a clean WAV, but the streaming pipeline needs the file to be the durable session source — it grows for the whole session and the poller derives snapshots from it. Keeping the recorder split as a sibling avoids overloading `dictate.sh` with a long-running concern and keeps the single-shot path zero-touch. Earlier streaming used `whisper-stream` (SDL2 capture) and bypassed the Apple Voice Processing IO unit — that produced unusable transcripts from the iMac internal mic and was rebuilt around `ffmpeg` for the same DSP coverage the single-shot path gets.

### Configurable values

| Variable | Default | Purpose |
|----------|---------|---------|
| `AUDIO_DEVICE` | from `config.local.sh` | Shared with [dictate.sh](dictate.sh) — same AVFoundation index, same DSP. |

### Size budget

Soft cap 200 lines, currently ~90. Split triggers: a second subcommand, or per-recording post-processing distinct from the single-shot path.

## [stream-server.sh](stream-server.sh)

```
stream-server.sh start [port]       spawn whisper-server on loopback
stream-server.sh stop               kill the daemon
stream-server.sh status             "running PID …" / "stopped" (exit 0/1)
```

The streaming inference daemon — `whisper-server` loaded once with the configured model, listening on `127.0.0.1:8472` by default. Each Lua poll POSTs a finalised WAV snapshot to `/inference`; the daemon returns `{"text":"…"}`. Without the daemon, every poll would pay ~500ms-1s to reload the model.

### Contracts

- **`start`** — idempotent. If a prior PID file points at a live process, exits 0 without spawning a second. Waits up to `READY_TIMEOUT_S` (20s) for the listener to bind before declaring success; the model load happens during that window. Writes the PID + log under the repo-local `tmp/` directory (project rule: never `/tmp` — see [CLAUDE.md][claude-md] § Scratch paths).
- **`stop`** — SIGTERM with a 2.5s patience, then SIGKILL. Removes the PID file regardless. Safe to call when nothing is running.
- **`status`** — pure read-only check; useful for shell verification independent of the Lua side.

### Configurable values

| Variable | Default | Purpose |
|----------|---------|---------|
| `MODEL_PATH` | from `config.local.sh` | Shared with [dictate.sh](dictate.sh). |
| `LANGUAGE` | from `config.local.sh` | Shared with [dictate.sh](dictate.sh). |
| `THREADS` | from `config.local.sh` | Shared with [dictate.sh](dictate.sh). |
| `STREAM_SERVER_PORT` | `8472` | Loopback port the daemon binds. Picked outside common dev-server ports to dodge collisions. |

### Size budget

Soft cap 200 lines, currently ~170. Split triggers: a streaming `/inference` long-poll mode, or a second daemon (e.g. an LLM cleanup pass) that warrants its own lifecycle helper.

## [test-record-shutdown.sh](test-record-shutdown.sh)

End-to-end test of `dictate.sh record` shutdown — reproduces what Hammerspoon does on PTT release without needing a keyboard. Four scenarios: `basic` (2s hold + SIGTERM), `rapid` (SIGTERM ~200ms after spawn), `no-orphans` (5 back-to-back cycles), `wav-duration` (3s hold preserves ≥2s of audio). Run after any change to `dictate.sh`. Override the mic with `AUDIO_DEVICE=:N`.

## [test-transcribe-output.sh](test-transcribe-output.sh)

Regression test against the `(B[m` ANSI prefix that leaked into pasted transcripts. Invokes `dictate.sh transcribe` two ways — directly and via `/bin/bash -c "…"` (Hammerspoon's `hs.execute` shape) — and asserts the output has no `\e` control bytes. Uses the bundled JFK fixture at `/opt/homebrew/share/whisper-cpp/jfk.wav`.

## [monitor-ghosts.sh](monitor-ghosts.sh)

Background watchdog that polls `pgrep` every 0.5s for `ffmpeg.*voice-dictate` and logs START/WAV/GONE transitions to `tmp/ghost-watch.log` (repo-local tmp/, never `/tmp` — see [CLAUDE.md][claude-md] § Scratch paths). Designed to catch orphan ffmpegs in the wild during long dictation sessions — complementary to `test-record-shutdown.sh`'s automated coverage. Subcommands: `start | stop | status | tail | reset`.

[claude-md]: ../CLAUDE.md
