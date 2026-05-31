# 2026-05-31 — Pluggable streaming engines + settings substrate

Owner: thanpolas. Status: planned (not started). Extends the [supersession plan][supersedes-plan] and **softens** [D1 of the ffmpeg rebuild][rebuild-plan]: `whisper-stream` + SDL2 returns as an opt-in **experimental** engine alongside the stable `ffmpeg` + `whisper-server` path — it does not replace it and does not reverse the rebuild's verdict.

## Goal

Make the streaming backend a selectable **engine** with two implementations behind one contract:

- **`ffmpeg-server`** — today's stable path. Default. Untouched.
- **`whisper-stream`** — the resurrected SDL2 capture path. Opt-in, clearly marked experimental in the menu.

Selection lives in a new schema-driven **settings substrate** designed so the several more knobs and switches coming next (model, language, cadence, …) slot in by adding a schema row, not by hand-wiring each into the menu.

## Relationship to the ffmpeg rebuild

The [rebuild plan][rebuild-plan] scrapped `whisper-stream` for a hard reason: SDL2's CoreAudio path bypasses macOS's Voice Processing IO unit (AGC / noise-suppression / echo-cancel), and the iMac internal mic hallucinated training-data patterns without that DSP. The same mic via `ffmpeg` AVFoundation transcribed perfectly.

This plan does **not** dispute that. It re-admits `whisper-stream` strictly as a gated, warned, opt-in alternative for setups where it does behave (e.g. an external mic that needs no DSP, or a user who wants the lower-latency incremental window and accepts the risk). The DSP hazard is exactly why the engine ships behind an explicit experimental gate rather than as a peer default.

## Constraints

- **Engine A is untouched.** [`voice-dictate-stream.lua`][stream-lua] and its `bin/stream.sh` + `bin/stream-server.sh` keep their exact behaviour; they are merely *registered* as the `ffmpeg-server` engine. No edits to the working path beyond the registration seam.
- **The splice layer is shared and untouched.** [`voice-dictate-splice.lua`][splice-lua] keeps its substring-replace mechanic, D3 divergence skip, D4 clipboard snapshot, and D6 focus-stop. Both engines must therefore present the **same emission contract** to it (see D1).
- **AVFoundation stays the default.** A fresh install with no settings runs `ffmpeg-server`. Opting into `whisper-stream` is a deliberate menu action.
- **No new runtime dependencies.** `whisper-stream` ships inside `brew install whisper-cpp`, same as `whisper-server` and `whisper-cli`.
- **200-line soft cap per file.** Each new concern (settings, engine B, SDL2 picker) is its own module.
- **A visible experimental warning** must accompany the `whisper-stream` choice wherever it is selectable.

## Architecture

### The engine contract

Both engines satisfy one interface — the shape [`voice-dictate-stream.lua`][stream-lua] already exports:

```
engine.setEmissionHandler(fn)   -- fn(fullTranscriptSoFar: string), called per tick
engine.start(cfg)               -- idempotent boot of the engine's processes
engine.stop(onDone)             -- teardown; onDone() fires after the final emission
engine.isStreaming()            -- state query for the orchestrator + menu
```

**Emission contract (D1):** every emission is the *full dictation text so far* — a monotonically growing (occasionally tail-revised) string. The splice layer anchors on the previous full text and replaces it with the new one. Engine A already emits this (each tick is whisper-server's reading of the entire session WAV). Engine B must adapt its rolling-window output to match (see Engine B).

### Engine A — `ffmpeg-server` (stable, default)

[`voice-dictate-stream.lua`][stream-lua] as-is. [`voice-dictate-stream-mode.lua`][mode-lua] already composes it with the splice; the only change there is *which* engine module it `require`s, chosen from settings (see Engine selection).

### Engine B — `whisper-stream` (experimental)

Two resurrected files plus one new adapter concern:

- **`bin/stream-whisper.sh`** — the pre-rebuild whisper-stream invocation (recoverable from git `a1922e8:bin/stream.sh`): `exec whisper-stream --model --language --threads --step --length --keep --capture --keep-context`. Re-introduces the `STREAM_STEP_MS` / `STREAM_LENGTH_MS` / `STREAM_KEEP_MS` knobs with the spike-log defaults (500 / 10000 / 200). Capture device comes from settings, not the config file (see Config surfaces).
- **`hammerspoon/voice-dictate-stream-whisper.lua`** — the pre-rebuild stdout consumer (recoverable from git `a1922e8:hammerspoon/voice-dictate-stream.lua`): spawn the script via `hs.task`, consume stdout line-by-line, strip ANSI + the `[Start speaking]` marker + non-speech artefacts. **Plus** the emission adapter below.
- **The emission adapter (D3)** — `whisper-stream` emits the transcript of the last `--length` ms *window*, which scrolls as the user keeps speaking. That is **not** the full-transcript-so-far the splice needs. The adapter maintains a `committedPrefix`: on each window emission it computes the longest common prefix between the new window and the previous one, promotes the now-stable leading delta into `committedPrefix`, and emits `committedPrefix .. currentWindow`. The splice therefore always sees a growing full transcript. **Fallback:** if the common-prefix promotion proves lossy in practice, flip to append-only — emit `committedPrefix .. newSuffix` where `newSuffix` is the non-overlapping tail. Lossy mid-prefix revisions are accepted for an experimental engine.

### Engine selection

[`voice-dictate-stream-mode.lua`][mode-lua] reads the `engine` setting at `startSession` (not module load — so a menu change takes effect on the next session without `hs.reload()`, mirroring the mic picker), `require`s the matching engine module, registers `splice.applyEmission` as its handler, and starts it. Teardown is identical regardless of engine. The orchestrator holds a reference to the *active* engine for `stopSession`.

### Settings substrate

New **`hammerspoon/voice-dictate-settings.lua`** — a thin, schema-driven wrapper over `hs.settings` (NSUserDefaults), generalising the persistence pattern [`voice-dictate-mic.lua`][mic-lua] already uses for the mic:

```lua
local SCHEMA = {
  engine = {
    settings_key = "voice-dictate.engine",
    label = "Engine",
    default = "ffmpeg-server",
    choices = {"ffmpeg-server", "whisper-stream"},
  },
  sdl2_capture_id = {
    settings_key = "voice-dictate.sdl2CaptureId",
    label = "SDL2 capture device",
    default = "-1",
    choices = {"-1", "0", "1", "2", "3", "4"},
  },
}
-- M.get(name) -> value or default ; M.set(name, value) ; M.choices(name) ; M.label(name)
```

Future knobs (model, language, polling cadence, append-only toggle) are added as schema rows; the menu renders any enum-typed row as a checked-radio submenu, so new switches need no bespoke menu code. This is the "think forward" the request asked for: the engine toggle is the substrate's first consumer, not a one-off.

### Menu

[`voice-dictate-menu.lua`][menu-lua] gains an **Engine ▸** submenu built from `settings.choices("engine")` as checked-radio items. The `whisper-stream` item is labelled with a visible warning, e.g. `whisper-stream + SDL2  — ⚠ experimental`. While the experimental engine is the active selection, the dropdown's status header carries a second disabled line: `⚠ experimental engine active`. When `whisper-stream` is selected, an **SDL2 capture ▸** submenu appears and the AVFoundation **Microphone ▸** item is dimmed (it does not apply to SDL2 capture).

```
Dikta — Idle
─────────────
Start Dictation        ⌘⇧D
─────────────
Microphone ▸                         (dimmed when whisper-stream active)
Engine ▸     ● ffmpeg + whisper-server (stable)
             ○ whisper-stream + SDL2  — ⚠ experimental
SDL2 capture ▸                        (shown only when whisper-stream active)
─────────────
Open Console / Reload Config
─────────────
Show Hammerspoon Menu Icon
```

### SDL2 capture device picker — and its hard limit (D5)

The settled choice was a *separate SDL2 device picker*. Verification against the binary changes what that can be: `whisper-stream --help` exposes **no device enumeration** (only `-c ID`, default `-1`), and *any* `whisper-stream` spawn pays the full Metal-backend load (~11s observed on this M1), so a live device probe on a menu click is infeasible. There is no other tool that reports SDL2's device ordering (it differs from ffmpeg's AVFoundation indices).

Therefore the SDL2 picker offers a **fixed list of integer capture IDs** (`Default (-1)`, `0`–`4`) as checked-radio items persisted via the settings substrate, rather than named devices. The user selects by trial; the chosen integer is passed to `--capture`. This is a documented limitation of the experimental path, recorded here so it is not mistaken for an unfinished feature.

### Config surfaces

- **Shell (`bin/config.local.sh` via [`install/config.sh`][config-sh]):** re-add `STREAM_STEP_MS` / `STREAM_LENGTH_MS` / `STREAM_KEEP_MS` defaults, consumed only by `bin/stream-whisper.sh`. Defaults live locally in that script too, so existing config files load unchanged.
- **SDL2 capture ID** moves to `hs.settings` (live, menu-driven) and **supersedes** the old config-file `STREAM_CAPTURE_ID` key — the menu is the source of truth, passed to the script per session.
- **Lua (`voice-dictate-config.lua`):** add `stream_whisper_sh` (absolute path to `bin/stream-whisper.sh`, derived at install time alongside `stream_sh` / `server_sh`).

## Decisions

- **D1 — Emission contract is full-transcript-so-far.** Both engines emit a growing full string; the splice is untouched.
- **D2 — Engine A is registered, not rewritten.** Zero behaviour change to the stable path.
- **D3 — Engine B uses a committed-prefix adapter** (longest-common-prefix promotion) to satisfy D1; append-only is the dormant fallback.
- **D4 — Build the schema-driven settings substrate now.** Engine + SDL2 capture are its first two consumers; future knobs are schema rows.
- **D5 — SDL2 picker is fixed integer IDs.** Named enumeration is infeasible (no binary support, ~11s probe cost). AVFoundation picker is dimmed under engine B.
- **D6 — Experimental warning** appears both on the submenu item label and as a status-header line while the engine is active.
- **D7 — Engine + capture choices persist in `hs.settings`,** read at `startSession`, so changes apply on the next session with no reload — same model as the mic picker.

## Sequence of work

One atomic commit per step; engine A stays the default and behaviour-identical until step 5 flips the selection seam.

1. **Settings substrate.** Add `voice-dictate-settings.lua` (schema, get/set/choices/label). No consumer yet. Syntax-check; no behaviour change.
2. **Engine submenu (engine A only).** Wire the Engine ▸ submenu from settings; only `ffmpeg-server` registered, so the default is unchanged and the experimental row is inert until step 4. Status-header warning logic in place.
3. **`bin/stream-whisper.sh`.** Resurrect the whisper-stream recorder script with the `STREAM_*` knobs. Verify standalone from a terminal.
4. **Engine B module.** Add `voice-dictate-stream-whisper.lua` (stdout consumer + committed-prefix adapter) satisfying the engine contract. Verify it emits a growing full transcript in isolation.
5. **Engine selection seam.** `voice-dictate-stream-mode.lua` chooses the engine module from the `engine` setting at `startSession`. This is the step that makes the experimental row functional.
6. **SDL2 capture picker + menu gating.** Add the SDL2 capture submenu (fixed IDs), show it only under engine B, dim the AVFoundation picker under engine B.
7. **Install + config + docs.** `install/config.sh` writes `stream_whisper_sh` and the `STREAM_*` shell knobs; update [`bin/README.md`][bin-readme], [`hammerspoon/README.md`][hs-readme], and `INVENTORY.md` for the new files; this plan lands in the [plans switchboard][plans-readme].

## Trade-offs, risks, open questions

- **The DSP hallucination risk is not solved — it is gated.** Engine B can still produce garbage on a mic that needs Voice Processing. Mitigation is the warning + opt-in, nothing more. Documented as the engine's defining caveat.
- **~11s Metal load per session for engine B.** No daemon, so every session pays cold-start backend load; first text is delayed. Engine A's `whisper-server` stays resident and avoids this. Documented; not optimised in v1.
- **Rolling-window reconstruction is lossy** on genuine mid-prefix revisions (rare). Accepted for experimental; the append-only fallback exists if it bites.
- **SDL2 device naming is unavailable** (D5) — integer-only picker. If a cheap enumerator ever appears, the SDL2 picker upgrades to named devices without touching the settings substrate.
- **Branching:** this is a new body of work; per repo workflow it should land on its own branch off `main` and ship via PR, not on the current streaming branch. Confirm before implementation.

## Verification

- **Engine A regression** — with default settings, behaviour is byte-identical to today; existing `bin/test-*.sh` pass; manual PTT + toggle dictation unchanged.
- **Settings persistence** — select engine B, `hs.reload()`, confirm the choice survives (NSUserDefaults).
- **Menu** — experimental warning visible on the item and in the header under engine B; SDL2 submenu appears and Microphone dims under engine B; both revert under engine A.
- **Engine B (manual, hardware-dependent)** — select engine B, dictate, confirm text streams into the field; accuracy is hardware-dependent and the hallucination caveat applies. This is the non-testable audio surface per [CLAUDE.md][claude-md] § A4.

[supersedes-plan]: 2026-05-28-streaming-replaces-single-shot.md
[rebuild-plan]: 2026-05-28-ffmpeg-streaming-rebuild.md
[stream-lua]: ../../hammerspoon/voice-dictate-stream.lua
[mode-lua]: ../../hammerspoon/voice-dictate-stream-mode.lua
[splice-lua]: ../../hammerspoon/voice-dictate-splice.lua
[mic-lua]: ../../hammerspoon/voice-dictate-mic.lua
[menu-lua]: ../../hammerspoon/voice-dictate-menu.lua
[config-sh]: ../../install/config.sh
[bin-readme]: ../../bin/README.md
[hs-readme]: ../../hammerspoon/README.md
[plans-readme]: README.md
[claude-md]: ../../CLAUDE.md
