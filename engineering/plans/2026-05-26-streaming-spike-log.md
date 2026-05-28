# 2026-05-26 — Streaming transcription spike log

Companion to the [streaming transcription plan][plan]. Records the findings of the two spikes the plan lists under § Sequence of work — step 1 (`whisper-stream` emission semantics) and step 2 (clipboard-mediated splice). The scripts that produced these findings live under [`tmp/streaming-spike/`][spike-dir] (gitignored); this log is the durable record.

Each section pairs **method** (how the finding was obtained) with **decision** (how it feeds the production defaults / fallbacks in [`bin/stream.sh`][stream-sh] and [`hammerspoon/voice-dictate-stream.lua`][lua-stream]).

## Spike 1 — emission semantics

Script: [`tmp/streaming-spike/spike-1-emit.sh`][spike-1]. Runs `whisper-stream` against the default mic with the plan's defaults (`--step 500 --length 5000 --keep 200 --keep-context`) and prefixes every stdout line with millisecond-precision wallclock via `ts(1)` from moreutils. The log goes to `tmp/streaming-spike/spike-1.log`.

### Verified from the binary

- `whisper-stream` 1.8.4 is at `/opt/homebrew/bin/whisper-stream`. Symlink target: `Cellar/whisper-cpp/1.8.4/bin/whisper-stream` — confirms brew installs it as part of `whisper-cpp`, no separate cask.
- `--help` lists the exact flags the plan relies on: `--step`, `--length`, `--keep`, `--capture`, `--model`, `--language`, `--keep-context`. The binary's own defaults are `--step 3000 --length 10000 --keep 200`; the plan deliberately overrides step + length toward liveness.
- `--capture ID` takes a single integer device ID; absent (`-1`) selects SDL2's default. SDL2 ordering is independent of avfoundation's `MIC_INDEX` — confirms the plan's `STREAM_CAPTURE_ID` configuration item.
- The binary loads BLAS + MTL backends at startup; on this M1 the metal library bootstrap is ~40ms. Per-emission inference adds on top of that but only at the front of the stream — the model stays resident for the session.

### Deferred to user-run

The four characterizations the plan names (cadence, revision behaviour, per-emission inference latency, fall-off marker) require live mic capture and a human speaking real utterances. Audio I/O is one of the non-testable surfaces named in [`CLAUDE.md`][claude] § A4 — manual verification only.

Run [`spike-1-emit.sh`][spike-1], speak a long multi-clause utterance for ~20s, then inspect `spike-1.log`:

- **Cadence**: diff successive timestamps; expect ~500ms intervals once inference catches up. Decision rule: if median gap exceeds 700ms, raise [`STREAM_STEP_MS`][stream-sh] default to 1000.
- **Revision behaviour**: does emission N+1 contain a rewrite of words emitted in N, or only new appended content? Decision rule: revisions present → keep D1's splice mechanic as designed; append-only → flip [`hammerspoon/voice-dictate-stream.lua`][lua-stream]'s `STREAM_APPEND_ONLY` flag and the layer skips the substring replace, just appending the delta.
- **Per-emission inference latency**: stderr typically reports per-decode timing; capture and compare with `--step`. Decision rule: if inference > step, the pipeline is falling behind — raise step to 1000–1500.
- **Fall-off marker**: how do words exit the window? Whisper-cpp's stream example prints `[Start speaking]` markers and re-emits the current buffer each step; older content scrolls off when the audio it covered drops out of `--length`. Decision rule: rely on positional offset (count of bytes already committed) rather than a special marker — feeds the commit-promotion helper in the splice layer.

### Production defaults sourced from this spike

The plan's [§ Decisions D2][plan-d2] is the authoritative table. Until the user confirms cadence and revision behaviour empirically, those defaults ship as-is and the append-only fallback ships dormant behind `STREAM_APPEND_ONLY=false`. The fallback flips to `true` only if Spike 1 returns append-only on this hardware.

[plan]: 2026-05-26-streaming-transcription.md
[plan-d2]: 2026-05-26-streaming-transcription.md#decisions
[spike-dir]: ../../tmp/streaming-spike/
[spike-1]: ../../tmp/streaming-spike/spike-1-emit.sh
[stream-sh]: ../../bin/stream.sh
[lua-stream]: ../../hammerspoon/voice-dictate-stream.lua
[claude]: ../../CLAUDE.md
