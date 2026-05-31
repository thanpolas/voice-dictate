# 2026-05-31 — Streaming flush cadence: make the recorder write incrementally

Owner: thanpolas. Status: **blocked** — the proposed `-flush_packets 1` fix was tried live on 2026-05-31 and broke transcription (hallucinations / empty output); reverted. The root-cause analysis below still stands; the fix does not. See § Outcome. Extends [the ffmpeg streaming rebuild plan][rebuild-plan] and resolves its deferred **"inference cadence"** open question — but reframed by measurement: the bottleneck is the *recorder's disk-flush cadence*, not the inference cost on a growing buffer.

## Problem

Streaming is supposed to feel live: text appears and grows roughly every [`POLL_INTERVAL_S`][lua-stream] (2s). In real use it does not. The first transcript lands ~10–12s after speech start, and thereafter text updates in coarse chunks, not a 2s flow. The 2s poll cadence is real but mostly wasted.

## Root cause — measured, not theorised

The poll path snapshots the **on-disk** session WAV (`ffmpeg -i SESSION_WAV -c copy SNAPSHOT_WAV` in [`snapshotAndPost`][lua-stream]) and POSTs it to whisper-server. The recorder ffmpeg ([`bin/stream.sh record`][stream-sh]) buffers its WAV output and only writes to disk in **256 KiB blocks**. At the capture format (16 kHz, mono, `pcm_s16le` → 32 000 bytes/s):

```
262144 bytes ÷ 32000 bytes/s = 8.19 s of audio per flushed block
```

So the file on disk advances ~8.2s at a time. Two independent log artefacts confirm this from one real session (2026-05-31 17:02, `tmp/`):

- **Recorder side** ([`tmp/stream-session.log`], ffmpeg progress `size=`): plateaus at 256 KiB for ~8.5s, then jumps to 512, then 768, then 1024 — block-buffered output.
- **Server side** ([`tmp/stream-server.log`], whisper per-request duration): the audio actually processed steps `8.2 → 8.2 → 8.2 → 16.4 → 16.4 → 24.6 → 24.6 → 32.8 …` — multiples of 8.2s, repeated across consecutive polls.

Between flushes the snapshot bytes are identical, whisper returns identical text, and the dedup guard ([`text == lastDispatchedText`][lua-stream]) drops it. Net effect:

| Observation | Explanation |
|---|---|
| First text at ~10–12s | First 256 KiB block needs ~8.2s of audio to fill + 2s poll granularity + inference. |
| No 1–2s flow | Effective live granularity is ~8s; 3 of every 4 polls are byte-identical no-ops. |
| Persists after warmup | Warmup is paid once on the resident server; this gap is the *recorder's* buffering, every session. |
| Early "dead zone" | `tmp/stream-server.log` shows `Received request` with no matching `processing` line for the first polls — the partial WAV before the first flush is rejected. |

## What already works — do not regress it

- **Partial-WAV demux works.** The snapshot `ffmpeg -c copy` already reads a WAV that the recorder has not closed (the data-size header field is still a placeholder). Proof: we get 8.2s/16.4s transcripts at all. The only variable is *how many bytes are flushed*, not whether a partial file is parseable.
- **The finalize pass** ([`finalizeAndEmit`][lua-stream]) still catches the tail on stop and remains the safety net for short utterances.
- **The dedup guard** stays correct and desirable — it just fires far more than it should today.

## Proposed fix

Force the recorder to flush its output buffer per packet so the on-disk file grows continuously:

- **Primary:** add `-flush_packets 1` to the recorder ffmpeg invocation in [`bin/stream.sh record`][stream-sh]. This flushes the AVIO context after every packet write; the file then advances at packet granularity instead of in 256 KiB blocks, and each 2s snapshot sees ~2s of new audio.

This is a one-flag change on a single call site. It does not touch the snapshot path, the server, or the Lua orchestrator.

### Why this and not the alternatives

- **Re-architect to POST audio chunks instead of the file** — the rebuild plan's other deferred idea. Larger surface, and unnecessary: the file path already works once it flushes.
- **Shrink whisper's re-transcription cost (sliding window + `--prompt`)** — a *real* but *separate* concern (inference cost grows with session length). It does not cause the latency the user observes; flush cadence does. Kept out of scope below.
- **Lower `POLL_INTERVAL_S`** — pointless while the file only advances every 8s; revisit only after the flush fix lands.
- **Raise capture bitrate (higher sample rate / bit depth) to fill the 256 KiB block faster** — coincidentally halves the gap (32 kHz → 4.1s, 48 kHz → 2.7s per block) but is a band-aid: it exploits a fixed buffer size that may change across ffmpeg versions, never reaches sub-2s reliably, and `-flush_packets 1` makes byte rate irrelevant to latency. No accuracy gain either — whisper.cpp runs internally at 16 kHz mono and downsamples anything higher; 16-bit already exceeds speech-ASR dynamic range. Staying at 16 kHz / 16-bit / mono also keeps one capture contract shared with the single-shot [`bin/dictate.sh`][dictate-sh] path.

## Out of scope — explicitly deferred

- **Growing-buffer inference cost.** Re-transcribing the entire session WAV every tick is O(session length). This plan does not address it; it remains the rebuild plan's open question and earns its own dated plan if it bites. One body of work per plan.
- **Tuning `POLL_INTERVAL_S`.** Only meaningful once the recorder flushes incrementally.

## Sequence of work — one atomic commit per step

### Step 1 — Empirical flush-cadence probe (no production change)

In `tmp/`, run the recorder with and without `-flush_packets 1` while polling the file size, to confirm: (a) the flag makes the on-disk file grow smoothly, and (b) what the real packet granularity is (avfoundation input packet size may itself floor the cadence below 2s — verify it is sub-second). This is the experiment that validates the fix before it touches the shipped script. Record the numbers here in this plan.

**Result (2026-05-31)** — probe used lavfi `anullsrc` + `-re` to isolate the output path (same 16 kHz / mono / `pcm_s16le` muxing, no mic dependency). Logs: `tmp/probe-baseline.log`, `tmp/probe-flush.log`.

| Run | On-disk `size=` cadence over 20s |
|---|---|
| Baseline (no flag) | Plateaus at **256 KiB from 8.44s → 16.12s**, then jumps to 512 KiB. Reproduces the ~8s block exactly — with a *synthetic* source, proving the stall is the output/AVIO buffer, not the mic. |
| `-flush_packets 1` | **Smooth monotonic growth** (~16 KiB per ~0.5s ≈ the 32 KB/s real-time rate), no plateaus through 625 KiB. |

Conclusion: the flag eliminates the block stall; a 2s snapshot will see ~2s of fresh audio per tick. Caveat: `anullsrc` emits 64 ms frames, so this proves the *output* path but not the real avfoundation input packet size — that floor is confirmed against a live mic in Step 3 (audio I/O is a manual-verification surface).

### Step 2 — Add `-flush_packets 1` to the recorder

Single-flag change to the ffmpeg call in [`bin/stream.sh record`][stream-sh]. Update the docblock/inline comment to name *why* the flag is load-bearing (the snapshot poller depends on incremental on-disk growth — without it the file advances in 256 KiB ≈ 8.2s blocks). Per A2, no new literal escapes into a call site that should be a constant; `-flush_packets 1` is an ffmpeg mechanic, not a configurable value.

### Step 3 — Re-measure and reconcile docs

Re-run a real session, confirm from `tmp/stream-server.log` that processed durations now step in ~2s increments, and that first text lands within a couple of seconds of warmup. Update [`bin/README.md`][bin-readme] and [`hammerspoon/README.md`][hs-readme] if any latency claim they make about the streaming pipeline is now stale.

## Verification

- `tmp/stream-server.log` shows processed-audio durations advancing in ~2s steps (not 8.2s) across a long utterance.
- First visible transcript within ~2–4s of speech start on a warm server.
- No regression in the finalize pass (short "1,2,3" utterances still land via stop), and the dedup guard no longer suppresses legitimate growth.

## Outcome — `-flush_packets 1` rejected (2026-05-31)

The flag landed in [`bin/stream.sh`][stream-sh], the Step 1 silence-probe passed (file grew smoothly), but the **live mic session was a hard fail**: transcription returned hallucinations or nothing at all. Reverted immediately; `bin/stream.sh` is back to the pre-fix recorder, and the README divergence note was rolled back with it.

Why the probe missed it: the probe used `anullsrc` (silence) and only measured *file growth cadence*. It proved the flush flag defeats the 256 KiB buffer, but it was blind to *audio integrity*. Per-packet flushing appears to let the snapshot `ffmpeg -c copy` capture torn/partial packets far more often, handing whisper malformed PCM — garbage in, hallucination out. A growth-only probe can never catch this; only a real-speech session can.

Lesson for the next attempt: any candidate fix must be verified against **real speech and a real transcript check**, not just file-size growth. The root cause (256 KiB block buffering → ~8s effective granularity) is unchanged and still worth solving — but not this way. Directions left to explore (none validated): a smaller AVIO buffer instead of per-packet flush; having the poller snapshot a fixed trailing window rather than the whole growing file; or accepting the ~8s recorder cadence and instead lowering latency on the inference side.

## Trade-offs and open questions

- **Write amplification.** Per-packet flushing increases syscall count, but at 32 KB/s the cost is negligible on any modern disk.
- **Packet-granularity floor.** If avfoundation hands ffmpeg packets larger than ~2s, the flush flag alone will not reach 2s cadence; Step 1 measures this. Mitigation if needed: an input framing flag, decided after measurement — not guessed now.
- **Torn final block on snapshot.** A snapshot taken mid-flush may copy a torn trailing packet → that one POST is dropped/AVERROR; the next tick recovers. Already the case today; the fix does not worsen it.

[rebuild-plan]: 2026-05-28-ffmpeg-streaming-rebuild.md
[lua-stream]: ../../hammerspoon/voice-dictate-stream.lua
[stream-sh]: ../../bin/stream.sh
[dictate-sh]: ../../bin/dictate.sh
[bin-readme]: ../../bin/README.md
[hs-readme]: ../../hammerspoon/README.md
[`tmp/stream-session.log`]: ../../tmp/stream-session.log
[`tmp/stream-server.log`]: ../../tmp/stream-server.log
