# 2026-06-03 — Scratch-path regression from the Dikta rename

Owner: thanpolas. Status: settled. Fixes a recording-dead regression introduced by the [rename clean-cut][clean-cut] / [rename plan][rename-plan] work and shipped in the merge of PR #5.

## Symptom

Push-to-talk appeared completely broken: pressing Right Option flashed the menubar between the recording and idle states, nothing was recorded, nothing was pasted, and on release the finalize spinner span forever and never returned to idle.

## Root cause — a one-letter spelling split between product and directory

The rebrand named the product **Dikta** while the repo checkout on disk is the differently-spelled **`dicta`**. `install.sh` resolves the real checkout location and writes correct `dicta` paths into `dikta-config.lua` (`stream_sh`, `server_sh`), and these are passed to the stream module as `cfg`.

But [`hammerspoon/dikta-stream.lua`][stream] derived the repo-local scratch directory — and therefore the session WAV and per-tick snapshot — from a **hardcoded module-load constant** (`DEFAULT_STREAM_SH`), not from the runtime `cfg.stream_sh`. The rebrand had spelled that constant `…/myStash/dikta/bin/stream.sh` (the product spelling), so the derived scratch dir was `…/myStash/dikta/tmp` — a directory that **does not exist** (only `dicta` does).

This violated [CLAUDE.md § Scratch paths][claude-md]: *"Lua modules derive it from the script-path config (`cfg.stream_sh` etc.) by stripping `/bin/<file>`."* The code derived it from a constant instead, so the documented protection against exactly this divergence was not in force. The rename then exposed the latent bug.

Two failure modes followed from the missing directory:

- **D1 — No capture.** `bin/stream.sh record` was told to write the WAV into a nonexistent dir, so ffmpeg failed to open its output and exited immediately on PTT press. Every poll snapshot read the same missing session WAV and failed too. No audio, no transcript.
- **D2 — Stranded finalize.** Because ffmpeg died *on press* (not on the SIGTERM at release), its one-shot exit callback fired while `pendingOnDone` was still nil. On release, `M.stop()` stashed the real teardown callback in `pendingOnDone` expecting the exit callback to fire again — but it already had and never would. The splice teardown and `menu → idle` were never invoked, so the spinner span forever.

## Fix

**F1 — Derive scratch paths from the runtime `stream.sh`, per the documented rule.** `SESSION_WAV` / `SNAPSHOT_WAV` are no longer module-load constants. Their basenames are named constants (`SESSION_WAV_NAME`, `SNAPSHOT_WAV_NAME`); the containing `tmp/` dir is computed at session start by `deriveScratchPaths(streamSh)` from the *resolved* `cfg.stream_sh`, so it always tracks the real checkout. The `DEFAULT_STREAM_SH` / `DEFAULT_SERVER_SH` fallback constants were also corrected `dikta` → `dicta`.

**F2 — Never strand the finalize spinner (defense-in-depth).** `M.stop()` now checks `ffmpegTask:isRunning()`. If the recorder is already dead, it fires `onDone` directly rather than waiting for an exit callback that will never come. A failed recorder now degrades to "no transcript + clean idle" instead of a permanent spinner.

## Verification

- Path derivation against `cfg.stream_sh` now yields `…/dicta/tmp/stream-session.wav`, a directory confirmed to exist.
- After a Hammerspoon restart, a live PTT session produced a fresh `dicta/tmp/stream-session.wav` + log and a transcribed paste. Confirmed working by the user.

## Follow-ups (not in this change)

- **A3 size cap.** [`dikta-stream.lua`][stream] is now 388 lines, over the 300-line hard stop (it was already 347 pre-fix — a pre-existing violation). It needs a split (e.g. poll-cycle vs. lifecycle) and was deliberately not bundled into this hotfix.
- **Startup latency.** First text lands ~3–5s after press: the `POLL_INTERVAL_S = 2.0` first-poll wait plus first-snapshot inference. Tuning (shorter interval, or an immediate first poll) is a separate enhancement with its own trade-offs.

[clean-cut]: 2026-06-01-dikta-rename-clean-cut.md
[rename-plan]: 2026-05-26-rename-to-dikta.md
[stream]: ../../hammerspoon/dikta-stream.lua
[claude-md]: ../../CLAUDE.md
