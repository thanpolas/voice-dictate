# 2026-06-03 — Split dikta-stream into focused modules

Owner: thanpolas. Status: settled. Follows the [scratch-path regression fix][regression], which left [`dikta-stream.lua`][stream] at 388 lines — over the A3 300-line hard stop.

## Why this exists

[`dikta-stream.lua`][stream] had accreted three distinct concerns into one file: ffmpeg-binary location, the per-tick transcription mechanics (snapshot → POST → parse → dispatch), and the session lifecycle (recorder task, poll timer, start/stop/state). At 388 lines it breaks the [conventions][conventions] A3 cap, and the ffmpeg-location logic was duplicated verbatim in [`dikta-mic.lua`][mic]. This plan records the decomposition.

## Decision

**D1 — Three Lua units, one shared helper.**

- **`dikta-ffmpeg.lua`** (new) — `M.resolve(fromCfg)` returns the absolute ffmpeg path: explicit cfg value wins, else probe the two Homebrew prefixes. Pure; no mutable state. Required by both the stream pipeline and the mic picker, replacing the copy-pasted `pathExists`/`resolveFfmpegPath` that lived in each.
- **`dikta-stream-infer.lua`** (new) — the inference poll cycle. Owns the dedup guard (`lastDispatchedText`), the in-flight guard (`pollInFlight`), the emission handler, and the per-session config (ffmpeg path + the two scratch WAV paths) set via `M.configure`. Exposes `configure`, `setEmissionHandler`, `resetDedup`, `pollOnce`, `finalize(onDone)`. Knows nothing about hotkeys, timers, or the recorder process — only how to turn the current session WAV into one dispatched emission.
- **`dikta-stream.lua`** (slimmed) — lifecycle orchestrator only. Owns `isStreaming`, the recorder `hs.task`, the poll `hs.timer`, and `pendingOnDone`. Derives the scratch paths from the runtime `stream.sh` (the regression fix), resolves ffmpeg via `dikta-ffmpeg`, configures `dikta-stream-infer`, and drives it from the timer + the recorder's exit callback.

**D2 — Public API and module name unchanged.** `dikta-stream.lua` keeps its name and its `setEmissionHandler` / `start` / `stop` / `isStreaming` surface, so [`dikta-stream-mode.lua`][mode] — the only consumer — needs no change. `setEmissionHandler` now delegates to the infer module.

**D3 — No behaviour change.** This is a pure relocation. Poll cadence, dedup, the always-run final pass, the SIGTERM teardown, and the `isRunning()` guard from the regression fix are all preserved verbatim. Log prefixes split for locatability: `[dk-ffmpeg]`, `[dk-infer]`, `[dk-stream]`.

**D4 — Symlinks need no installer change.** [`install/hammerspoon.sh`][install] globs `hammerspoon/*.lua`, so the two new modules are linked into `~/.hammerspoon/` on the next install/reload automatically. Existing checkouts get them symlinked the same way.

## Consequence

Each resulting file sits under the 200-line soft cap. The ffmpeg-location logic now has a single home, so a change to the probe order touches one file. The infer module is independently testable in principle (configure with fixture paths, assert dispatch), though audio I/O remains manually verified per A4.

[regression]: 2026-06-03-scratch-path-rename-regression.md
[stream]: ../../hammerspoon/dikta-stream.lua
[mic]: ../../hammerspoon/dikta-mic.lua
[mode]: ../../hammerspoon/dikta-stream-mode.lua
[install]: ../../install/hammerspoon.sh
[conventions]: ../conventions.md
