# 2026-05-26 — Streaming / on-the-fly transcription

Owner: thanpolas. Status: draft — architecture committed (B-step); calibration deferred to spike.

This plan reopens a decision the [v0.1 spec][v01-spec] made deliberately. Under § Non-goals: "Streaming / partial transcription. Record-then-transcribe is fine for utterances under ~30s." That bought v0.1 accuracy-first behaviour and a dead-simple pipeline. This plan is the source of truth for the streaming contract going forward and reopens that non-goal as an opt-in mode.

## Goal

Text appears in the focused field **while the user is still speaking** — within ~1s of speech start, not after a clause-ending pause and not after the user stops. Earlier text gets *revised in place* as the model hears more context and changes its mind about what was said.

Target surface: plain-text fields — prompt boxes (Claude Code input, browser chat inputs), search bars, single-line and plain-textarea inputs, Terminal prompts. Rich-text editors (Slack, Gmail, Notion, iMessage) are explicitly out of scope: `Cmd+X` on styled content yields RTF/HTML the splice cannot reliably modify.

The architectural commitment: a long-lived `whisper-stream` process emits revisable hypotheses over a sliding audio window; the paste layer replaces our pasted region in-place on each emission via clipboard-mediated splice. This is the only shape that gets text on-screen *as you speak* — the alternatives only emit at clause boundaries. See [Historical alternatives][hist].

## What changed since the v0.1 non-goal was set

Four things, none of which were true at v0.1 lock:

- **The pipeline is already async and decoupled.** Transcription runs on `hs.task`; [`startRecording`][lua] fires from the record task's own exit callback. The machinery to spawn a long-lived child, stream stdout, and react to it incrementally already exists. Streaming is a different consumer of the same seam, not a new architecture.
- **Long-utterance latency is a known sore point.** v0.1 Open Question 3 flags that a 60s utterance costs ~12s of dead wait at ~5x realtime. Streaming collapses that tail entirely.
- **`whisper-stream` is installed.** Verified 2026-05-28: `/opt/homebrew/bin/whisper-stream` ships with `brew install whisper-cpp` (1.8.4 on this machine). SDL2 bundled via the formula's build deps. No install-time work needed.
- **Clipboard-mediated splice is viable for plain-text fields.** `Shift+Cmd+Up` extends selection from cursor to start of document on native macOS text views, leaving any suffix the user has typed untouched. `Cmd+X` cuts that range to the clipboard; we modify the clipboard string in code (find our last-pasted dictation, replace with the new emission); `Cmd+V` paints the result back. Cursor lands at end-of-paste — equivalent to live-typing. No accessibility-API fragility, no per-app "select last N chars" primitive needed.

## Constraints

- macOS-only, Apple Silicon. ffmpeg + avfoundation + whisper.cpp + Hammerspoon Lua only. No new runtime ([conventions.md][conventions-md] § Shell/Lua specifics).
- Target plain-text fields only. Rich-text scope is excluded by design, not deferred.
- The proven `record` / `transcribe` path stays the always-available floor. Streaming layers beside it, opt-in, and does not modify the single-shot pipeline.
- 200-line soft cap applies. `dictate.sh` is ~100 lines; streaming is a clean split trigger — new sibling `bin/stream.sh`, not inlined into `record` / `transcribe`.
- Accuracy-first remains the v0.1 mandate *for the default path*. Streaming sacrifices accuracy for liveness — single-pass `whisper-cli` on a full utterance will outperform sliding-window streaming. This is a deliberate trade, justified by mode-opt-in (D5).

## Decisions

**D1 — Architecture: `whisper-stream` step mode + clipboard-mediated splice.**

A single long-lived `whisper-stream` process owns audio capture and sliding-window inference. Every `--step` ms it emits the current transcription of the recent audio window to stdout. Hammerspoon consumes the stream via `hs.task` stdout callbacks. On each emission, the Lua paste layer:

1. Computes the new full dictation text — combination of the committed prefix accumulated so far plus the latest emission's content (see D2 for the commit-vs-tail distinction).
2. Synthesizes `Shift+Cmd+Up` (extend selection from cursor to start of document on macOS native text views).
3. Synthesizes `Cmd+X` (cut selection to clipboard).
4. Reads the clipboard, finds the substring matching our **last-pasted dictation text**, replaces it with the new full text.
5. Writes the modified string back to the clipboard.
6. Synthesizes `Cmd+V`.
7. Updates state: `last_pasted_dictation_text` = new full text.

Cursor lands at end-of-paste, exactly where it would be after live-typing. Any pre-existing field content *before* our dictation anchor is preserved (cut and re-pasted alongside our revision in the same `Cmd+V`). Any pre-existing content *after* the cursor is never selected and never touched.

**D2 — Whisper-stream parameters and the commit-vs-tail distinction.**

`whisper-stream` in step mode emits the transcription of overlapping audio windows: emission N covers `[t_N, t_N + length]`; emission N+1 covers `[t_N + step, t_N + step + length]`. The two overlap by `length - step` ms. The same audio gets transcribed multiple times with increasing context — that's where revisions come from.

| Flag | Default | Rationale |
|---|---|---|
| `--step` | 500 | Emit every 500ms. The example default of 3000ms is too slow to feel live; 500ms is the threshold where revisions feel responsive without thrashing the paste mechanic. |
| `--length` | 5000 | 5s sliding window — long enough to give whisper meaningful context, short enough to keep per-emission inference fast (~hundreds of ms on Apple Silicon). |
| `--keep` | 200 | Carry 200ms of prior window into next emission for boundary continuity. |
| `--model` | inherited from today's `MODEL` env | Same model the single-shot path uses. |
| `--language` | inherited from today's `WHISPER_LANG` | Same as today (auto / `el` / `en` / etc.). |
| `--capture` | from `STREAM_CAPTURE_ID` env | SDL2 device index; **not** the same as ffmpeg's `MIC_INDEX` — calibration item (see [Calibration notes][cal]). |

All are tunable as config keys (`STREAM_STEP_MS`, `STREAM_LENGTH_MS`, `STREAM_KEEP_MS`, `STREAM_CAPTURE_ID`).

**Commit-vs-tail logic.** Audio older than `--length` ms falls out of whisper-stream's window and stops appearing in future emissions. The paste layer must promote those words from the "live tail" (revisable) to the "committed prefix" (final). The simplest workable algorithm: keep state of `committed_prefix` (string) and `live_tail` (string). On each emission, compute how much audio has dropped off the front of the window since the last emission; the corresponding word-prefix of the previous emission becomes part of `committed_prefix`. The remainder of the new emission becomes the new `live_tail`. The full dictation pasted is `committed_prefix + live_tail`. Exact algorithm is calibration-driven (sequence step 1 reveals what whisper-stream actually emits).

**D3 — State divergence policy.**

When the splice cuts the field contents to the clipboard, we expect to find `last_pasted_dictation_text` as a substring. Two cases:

- **Found**: splice as normal — replace it with the new full dictation text, paste.
- **Not found**: the user has edited our text manually (corrected a word, added punctuation). **Skip the splice.** Write the original cut contents back to the clipboard, paste, take no action on this emission. The user's edit is preserved; the model's revision is discarded for this cycle. On the next emission, try again — the model may have updated to match the user's intent.

Exact substring match, no fuzzy matching, no recovery heuristics. One conditional.

**D4 — Clipboard preservation.**

Today's single-shot path clobbers the clipboard once per utterance. Streaming clobbers it once per `--step` (every 500ms at defaults). Mitigation:

1. Snapshot the pasteboard via `hs.pasteboard.getContents` on streaming-session start.
2. Use the general pasteboard for splice operations (named pasteboards don't reliably interop with synthetic `Cmd+V` across all apps — verified in sequence step 2).
3. Restore the snapshot on streaming-session end.

Mid-stream the clipboard is unusable — if the user manually copies something while streaming is active, our next splice overwrites it. Documented limitation. Mitigated by streaming being opt-in (D5).

**D5 — Opt-in mode: separate hotkey, default unchanged.**

Streaming is **not** the new default. It is selected per-utterance via a distinct hotkey (e.g. `Cmd+Shift+S` alongside the existing record hotkey). The single-shot path keeps its hotkey, behaviour, and accuracy unchanged. A `cfg.streaming_default = true` config flag is the durable "make streaming the default" toggle, decided after sequence step 7's empirical measurement.

Streaming trades accuracy for liveness. Single-pass `whisper-cli` on a full utterance is more accurate than `whisper-stream`'s sliding-window mode. The user picks per utterance: single-shot when accuracy matters (final commit messages, important prose), streaming when liveness matters (interactive prompt iteration).

**D6 — Focus-loss policy.**

If the focused application or text field changes mid-stream, the splice would land in the wrong place. The streaming session subscribes to `hs.window.filter` focus events; on focus loss, it **stops the stream immediately** (kill `whisper-stream`, flush state, restore clipboard, no further pastes). The user must explicitly re-trigger streaming after re-focusing. Better than guessing where to resume.

## Sequence of work

1. **Spike `whisper-stream` emission semantics.** Run the binary against the mic with the shipped defaults; observe stdout. Characterize: (a) cadence — actual ms between emissions, (b) revision behaviour — do successive emissions revise the same words, or are they non-overlapping?, (c) per-emission inference latency on this hardware, (d) how words "fall off" the window (special marker? just absent from next emission?). This is the riskiest unknown; everything downstream depends on it. If emissions are append-only rather than revisable, D1's mechanic still works but degenerates — the latency story still beats the alternatives, but the "text gets corrected as you speak" UX disappears.
2. **Spike clipboard-mediated splice in isolation.** A throwaway Hammerspoon script that takes a hardcoded `(old_text, new_text)` pair and runs the `Shift+Cmd+Up` → `Cmd+X` → modify → `Cmd+V` chain into the currently-focused field. Test against the target field list: Claude Code input, ChatGPT / Claude.ai chat input, Terminal prompt, browser address bar, macOS Spotlight, native single-line input. For each: cursor lands where expected? Pre-existing prefix preserved? Flicker tolerable at one cycle per 500ms? Any field that fails goes on a documented blocklist.
3. **CDE the new concern.** Add [`bin/stream.sh`][stream-sh] with `@fileoverview` and a stub that launches `whisper-stream` with the chosen flags. Add the streaming section to [`bin/README.md`][bin-readme] (config keys, target-field scope, accuracy caveat). Add the streaming-mode section to [`hammerspoon/README.md`][hs-readme].
4. **Wire `whisper-stream` through Hammerspoon.** `hs.task` on `bin/stream.sh`; stdout callback receives emissions; emissions processed serially (one at a time — whisper-stream is single-producer from our side).
5. **Implement the splice paste layer.** Lua-side state: `committed_prefix`, `live_tail`, `last_pasted_dictation_text`, pasteboard snapshot. The keystroke chain. The substring divergence check (D3). The focus-loss stop (D6). Pasteboard restore on session end (D4).
6. **Mode switch.** Wire the separate streaming hotkey; ensure single-shot is untouched.
7. **Measurement on real workload.** Long, multi-pause prompts in real target apps. How does it *feel*? Does revision flicker annoy or help? Does accuracy degrade enough to matter for prompt entry? Go/no-go on flipping `cfg.streaming_default = true`.
8. **Docs.** `bin/README.md`, `hammerspoon/README.md`. INVENTORY entry is the orchestrator's to add.

## Cross-doc effects

- [`bin/README.md`][bin-readme] — new `stream.sh` section; new config keys (`STREAM_STEP_MS`, `STREAM_LENGTH_MS`, `STREAM_KEEP_MS`, `STREAM_CAPTURE_ID`); target-field scope note (plain-text only); accuracy-cost caveat.
- [`hammerspoon/README.md`][hs-readme] — streaming hotkey, splice mechanic explained, divergence-skip rule, focus-loss policy, pasteboard preservation behaviour.
- [`dictate.sh`][dictate] header — no behaviour change to single-shot; mention sibling `stream.sh` in the file overview.
- [v0.1 spec][v01-spec] § Non-goals — explicitly reopens "Streaming / partial transcription" as an opt-in mode (D5). Spec stays frozen as historical; this plan is the streaming contract.
- [Install bootstrapper plan][install-plan] — no change. `brew install whisper-cpp` already installs `whisper-stream` with SDL2 bundled.
- `INVENTORY.md` and the plans switchboard — new `bin/stream.sh` and this plan need entries; out of scope for this plan to edit.

## Risks

- **`whisper-stream` emission semantics may not be revisable in practice.** D1 assumes successive emissions can rewrite overlapping audio. If step mode actually emits non-overlapping append-only chunks, the splice degenerates and the "text corrects as you speak" UX is lost — though latency to first text still beats the alternatives. Sequence step 1 settles this before any paste-layer code is written. Fallback: append-only splice still works; document the simplification.
- **Splice cadence flicker.** Every emission is a select → cut → paste cycle. At `--step 500`, that's twice per second of visible flash on the field. Step 2 confirms whether real-world feel is acceptable; if not, raise `--step` to 1000 or 1500 in defaults — trades liveness for calm.
- **Accuracy regression vs single-shot.** `whisper-stream` over a 5s sliding window cannot match `whisper-cli` over a full utterance, and there is no per-chunk `--prompt` priming available in step mode. Mitigation: streaming is opt-in (D5); the user picks accuracy when they need it.
- **State divergence corner cases beyond D3.** Substring-match-or-skip handles "user edits our text." Does not handle: app loses focus mid-stream (D6 covers — stop the stream), modal dialog steals input, user clicks elsewhere in the same field. The last case is the ugliest: the cursor moves, `Shift+Cmd+Up` selects from the new cursor position, and the splice can rebuild around our text or corrupt depending on where they clicked. Mitigation: spike (step 2) tests this; if unrecoverable, the streaming-mode README documents "don't click around mid-stream."
- **Clipboard clobber, mid-stream.** Per-step throughout the session. Snapshot/restore (D4) covers session boundaries; the user copying something mid-stream loses it. Opt-in mode + documentation.
- **`whisper-stream` lifecycle replaces today's proven SIGTERM/WAV-flush invariants.** New process, new shutdown semantics. Verify cleanly killing `whisper-stream` mid-emission doesn't leave the audio device open, stdout half-flushed, or a zombie SDL2 audio context. This is new code; existing `bin/test-record-shutdown.sh` doesn't cover it. Add a manual repro for the streaming-stop path.
- **SDL2 capture device numbering differs from avfoundation.** Today's `MIC_INDEX` (avfoundation's ordering) does not map to `whisper-stream`'s `--capture` (SDL2's ordering). The user may need to separately configure `STREAM_CAPTURE_ID`. The spike (step 1) enumerates devices via `whisper-stream` and the bootstrapper or README documents the mapping.

## Calibration notes

Empirical items the spikes (steps 1–2) settle. Each has a method and a decision rule — not punted questions.

- **Emission semantics**: step 1, by running the binary and observing stdout. Decision: revisable → D1 mechanic as written; append-only → splice degenerates to append, document the simplification, ship.
- **Cadence defaults**: step 1, by measuring actual emission interval and per-emission inference time. Decision: if 500ms feels jittery or inference exceeds 400ms/step, raise `--step` to 1000ms.
- **Window length**: step 1, by reading transcript quality across short vs long utterances. Decision: if 5s window drops the start of a 7s thought, raise `--length` to 8000.
- **SDL2 capture mapping**: step 1, by running `whisper-stream --list-devices` (or equivalent) and matching against the user's expected mic. Decision: document `STREAM_CAPTURE_ID` in the bootstrapper output.
- **Per-app splice reliability**: step 2, against the target field list. Decision: any field where the splice fails — wrong cursor position, partial paste, app-specific keybinding collision — goes on a documented blocklist; streaming refuses to engage when focused there.
- **Flicker tolerance**: step 2, subjective. Decision: if visibly jittery in any target app at the calibrated `--step`, raise `--step` further.
- **Click-mid-stream behaviour**: step 2. Decision: if unrecoverable, document "don't click mid-stream" in the README; if mild, leave the splice to self-correct on the next emission.

## Historical alternatives

Two architectures were seriously considered before B-step was chosen. They are documented here so the rejection is a decision, not an omission.

**Shape A — chunked segment-and-transcribe, our orchestration.** Keep ffmpeg recording continuously. Detect silence boundaries on the live stream via ffmpeg `silencedetect`. Fire `whisper-cli` per *closed* segment with `--prompt` priming from the prior segment for left-context. Paste each segment's text as it finalizes via append-only `Cmd+V`. Tuning triad: `STREAM_HANGOVER_MS` (~600), `STREAM_SILENCE_DB` (~-35), `STREAM_MIN_SEGMENT_MS` (~250).

- **Advantages**: per-chunk `--prompt` priming helps Greek+English code-switching and technical vocabulary; per-chunk WAVs on disk for debugging; preserves today's proven SIGTERM / WAV-flush / bash-wrapper signal-handling; finalize-only paste needs no splice.
- **Why rejected**: only emits text at clause boundaries. Latency to first text is ~1.2–2.1s *after a pause*, not after speech starts. For long uninterrupted thoughts (the user's stated workload), the first chunk doesn't close until the first pause — by which point the user has waited as long as today. Fails the "text appears while I speak" UX goal that motivates this plan at all.

**Shape B-vad — `whisper-stream` in VAD mode (`--step 0`).** Same `whisper-stream` binary, configured to wait for VAD-detected silence before emitting. Each emission is a finalized segment.

- **Advantages**: model stays loaded across the utterance (saves ~200–500ms per-chunk model load vs A); simpler than A — one process, no ffmpeg orchestration.
- **Why rejected**: same latency profile as A. Emissions only at silence boundaries. Loses to B-step on the live-text-while-speaking criterion.

Both alternatives are *more accurate* than B-step (A especially, with prompt-priming and chunk overlap). The choice of B-step is a deliberate accuracy-for-liveness trade, made viable by streaming being opt-in: when accuracy matters, the user picks the existing single-shot path; when liveness matters, they pick streaming.

**Paste-then-revise objections — rejected and rebuttal.** Earlier drafts of this plan rejected B-step "outright" on the grounds that synthetic-keystroke paste cannot retract pasted text — the AX API "select last N chars and replace" primitive is unreliable across apps. That framing was wrong. The clipboard-mediated splice (D1) bypasses the AX API entirely by using the clipboard as a working buffer:

- **Pre-existing field content** is preserved via `Shift+Cmd+Up` cutting only `[0, cursor]`, leaving any suffix untouched.
- **Cursor position** lands at end-of-paste — equivalent to live-typing the revised text.
- **User edits to our text** are detected via substring-match-or-skip (D3) and never clobbered.
- **App-specific keybinding collisions** (an earlier draft incorrectly attributed `Cmd+Shift+Up = Move Line Up` to VS Code — that's `Option+Up`; `Cmd+Shift+Up` is "extend selection to start" in VS Code as in native fields) do not apply to the target field set.

What remains — flicker cadence, rich-text scoping, divergence policy — is addressed by D3, D4, the constraints, and the calibration notes. Not architectural blockers.

[v01-spec]: 2026-05-20-v0.1-spec.md
[install-plan]: 2026-05-25-install-ux-bootstrap.md
[conventions-md]: ../conventions.md
[dictate]: ../../bin/dictate.sh
[stream-sh]: ../../bin/stream.sh
[bin-readme]: ../../bin/README.md
[lua]: ../../hammerspoon/voice-dictate.lua
[hs-readme]: ../../hammerspoon/README.md
[hist]: #historical-alternatives
[cal]: #calibration-notes
