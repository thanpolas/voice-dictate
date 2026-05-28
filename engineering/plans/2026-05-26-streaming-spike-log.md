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

## Spike 2 — clipboard-mediated splice

Script: [`tmp/streaming-spike/spike-2-splice.lua`][spike-2]. A standalone Hammerspoon snippet `dofile`-loaded into the Console. Exposes `spike2.run(old, new)` (one splice cycle) and `spike2.cycle({{old=,new=}, …})` (a sequence at the production cadence — 600ms gaps to approximate `--step 500` plus inference jitter). The user focuses each target in turn, calls the function, and notes the outcome.

### Verified from the keystroke semantics

- `Shift+Cmd+Up` is the documented macOS "extend selection to start of document" shortcut on native NSTextView / NSTextField surfaces. On single-line fields it collapses to "select to beginning of line," which still covers any text the splice could have pasted.
- `Cmd+X` cut-on-empty-selection is a no-op (preserves clipboard); cut-on-non-empty replaces the clipboard with the cut text. Either way, the post-cut clipboard read returns the field's prefix.
- `Cmd+V` round-trips plain-text clipboard contents byte-for-byte on plain-text targets. The plan's [§ Constraints][plan-constraints] excludes rich-text targets by design.
- `hs.pasteboard.getContents()` blocks until the cut has populated NSPasteboard. The 80ms `usleep` between the `Cmd+X` keystroke and the `getContents()` read is generous insurance for slow apps; tighten if the spike shows headroom.

### Deferred to user-run — target-field check list

Run [`spike-2-splice.lua`][spike-2] with `spike2.run("hello world", "hello brave world")` and `spike2.cycle({{old="a",new="ab"},{old="ab",new="abc"},{old="abc",new="abcd"}})` against each:

| Target | Cursor ends-of-paste? | Prefix preserved? | Flicker OK at 2 Hz? |
|---|---|---|---|
| Claude Code input (terminal) |  |  |  |
| ChatGPT / Claude.ai chat input |  |  |  |
| Terminal.app / iTerm prompt |  |  |  |
| Browser address bar (Safari, Chrome) |  |  |  |
| macOS Spotlight |  |  |  |
| Native `NSTextField` (Finder rename) |  |  |  |
| VS Code editor pane |  |  |  |
| TextEdit (plain text mode) |  |  |  |

### Per-app blocklist (initial)

Any field that fails any column lands in the splice layer's blocklist set (`hammerspoon/voice-dictate-stream.lua` once it lands in step 5). Streaming refuses to engage when focused there ([D6 focus-loss policy][plan-d6] covers mid-session focus changes — startup-time focus check is the corresponding entry guard).

Until the user runs Spike 2, the blocklist ships with the three documented-by-design exclusions from the plan's [§ Goal][plan-goal] / rich-text scope rule: Slack, Notion, and Mail/Gmail-compose (rich-text editors). These are scope-by-design, not spike-discovered.

### Click-mid-stream behaviour

The plan's [§ Risks][plan-risks] flags this as the ugliest divergence case. Spike 2's manual test: start `spike2.cycle(...)`, click elsewhere in the same field between pastes, confirm whether the next splice corrupts state or self-corrects via D3's substring-not-found skip. Decision: if it self-corrects on the next emission, no code change. If it corrupts, the streaming-mode README adds a "don't click mid-stream" caveat.

## Measurement on real workload (plan step 7)

Step 7 of the [plan][plan] — "Measurement on real workload. Long, multi-pause prompts in real target apps. How does it *feel*? Does revision flicker annoy or help? Does accuracy degrade enough to matter for prompt entry? Go/no-go on flipping `cfg.streaming_default = true`" — cannot be automated. The two questions it asks are subjective (how it feels) and workload-specific (the user's own dictation patterns). The agent cannot stand in for the user here.

This section is the verification checklist the user runs after the implementation lands. The outcome flips one bit in [`~/.hammerspoon/voice-dictate-config.lua`][hs-cfg] (`stream_default = true` to make streaming the new default, or leave `false` to keep it opt-in).

### Setup

1. Pull this branch and run `./install.sh` (writes the new streaming config keys + symlinks the new Lua siblings).
2. `hs.reload()` in the Hammerspoon Console. The startup print line should now name two hotkeys: `Toggle = Cmd+Shift+D, Stream = Cmd+Shift+S`.
3. Run [`tmp/streaming-spike/spike-1-emit.sh`][spike-1] once with a short utterance to confirm `whisper-stream` works against the active mic. If it fails: check `STREAM_CAPTURE_ID` (the SDL2 device ID is not the same as ffmpeg's `MIC_INDEX` — see the Spike 1 § Deferred-to-user-run notes).

### Workload

Use the streaming hotkey for ≥1 full day of real dictation across at least:

- A long multi-clause prompt to Claude Code or ChatGPT (target: ≥2 sentences, ≥1 mid-sentence pause).
- A short single-clause search query (Spotlight, browser address bar).
- A code identifier dictation (Terminal prompt, a variable name).
- A mid-utterance correction — start a sentence, change your mind, restart.

### Go/no-go criteria

Each is a "Yes" / "No" plus a sentence of qualitative detail. Decision rule listed inline.

- **Latency to first text** — does text appear within ~1s of speech start? If **No** → keep `stream_default = false`; streaming is not delivering the UX the plan was built around.
- **Revision flicker** — at the default `STREAM_STEP_MS=500`, is the visible re-paste rhythm tolerable or distracting? If distracting → raise `STREAM_STEP_MS` to 1000 in `bin/config.local.sh`, re-test. If still distracting after 1500 → streaming stays opt-in.
- **Accuracy regression vs single-shot** — re-dictate the same prompt with the single-shot hotkey and compare. If the streaming version requires ≥1 post-paste edit per ~20 words that the single-shot did not → keep `stream_default = false`.
- **Divergence skip behaviour (D3)** — edit a word mid-stream; does the next emission self-correct, or does it clobber the edit? If clobber → file a follow-up plan; do **not** flip the default.
- **Focus-loss stop (D6)** — switch apps mid-stream; does the session stop cleanly with the clipboard restored? If session leaks across apps → blocking; do not enable.
- **Per-app blocklist** — work through the Spike 2 target list. Each app that fails any column gets added to `stream_blocklist` in the config before the default flips.
- **Clipboard preservation (D4)** — `Cmd+C` something before a streaming session; after the session ends, paste — is the original content back? If not → leak; do not enable.

### Outcome

If every criterion is **Yes** for the user's real workload and target apps, set `stream_default = true` in `voice-dictate-config.lua` and open a follow-up plan that captures: (a) the per-app blocklist as discovered, (b) any defaults that needed tuning, (c) the conditions under which the user fell back to single-shot.

If any criterion is **No**, streaming stays opt-in. The plan's [§ D5][plan-d2] already commits to that being a viable steady state.

[plan]: 2026-05-26-streaming-transcription.md
[plan-d2]: 2026-05-26-streaming-transcription.md#decisions
[plan-d6]: 2026-05-26-streaming-transcription.md#decisions
[plan-goal]: 2026-05-26-streaming-transcription.md#goal
[plan-constraints]: 2026-05-26-streaming-transcription.md#constraints
[plan-risks]: 2026-05-26-streaming-transcription.md#risks
[spike-dir]: ../../tmp/streaming-spike/
[spike-1]: ../../tmp/streaming-spike/spike-1-emit.sh
[spike-2]: ../../tmp/streaming-spike/spike-2-splice.lua
[stream-sh]: ../../bin/stream.sh
[lua-stream]: ../../hammerspoon/voice-dictate-stream.lua
[hs-cfg]: ../../hammerspoon/README.md
[claude]: ../../CLAUDE.md
