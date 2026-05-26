# 2026-05-26 — Streaming / on-the-fly transcription

Owner: thanpolas. Status: draft — exploratory; revisits a v0.1 non-goal; open questions flagged.

This plan reopens a decision the [v0.1 spec][v01-spec] made deliberately. Under § Non-goals the spec wrote: "Streaming / partial transcription. Record-then-transcribe is fine for utterances under ~30s." That was the right call for shipping v0.1 — it bought accuracy-first behaviour and a dead-simple pipeline (one WAV, one `whisper-cli` run, one paste). This plan asks whether the calculus has changed and what a streaming pipeline would cost. It is Goal 2c in the command-center UX track. It does not supersede the v0.1 spec; the spec stays frozen as historical, and this plan becomes the source of truth for the streaming contract if and when it ships.

## What changed since the non-goal was set

Three things make streaming worth re-examining now, none of which were true at v0.1 lock:

- **The pipeline is already async and decoupled.** The 2026-05-24 changelog moved transcription off `hs.execute` onto `hs.task`, and [`startRecording`][lua] now fires transcription from the record task's own exit callback — not a timer. The machinery to spawn a long-lived child, stream its stdout, and react to it incrementally already exists; streaming is a different consumer of the same seam, not a new architecture.
- **Long-utterance latency is a known sore point.** v0.1 Open Question 3 flags that a 60s utterance costs ~12s of dead wait at ~5x realtime. Streaming's entire value proposition is collapsing that tail: text appears *while* you speak, so perceived latency at end-of-speech is near-zero regardless of utterance length.
- **whisper.cpp now ships first-class VAD.** Recent whisper.cpp has built-in Silero VAD (`--vad`) in `whisper-cli` itself, plus a dedicated `vad-speech-segments` tool and the long-standing SDL2 `whisper-stream` example. The "when to cut a segment" problem the user names is now partly solved by upstream tooling rather than something we must hand-roll from scratch.

What has **not** changed: the accuracy-first mandate. v0.1 § Goals: "Latency: accuracy-first. Up to ~5 seconds from speech end to pasted text is acceptable." Streaming trades accuracy for latency — be honest that this is a real cost (see [Decisions][decisions] D6 and [Risks][risks]), and that for short utterances streaming may be strictly worse than today.

## Goal

Transcribe segments of an utterance **on the fly while recording is still ongoing**, emitting text into the field as the user keeps speaking — instead of recording the whole utterance to a WAV, then transcribing once, then pasting. The user's framing names the crux: "the biggest question is when to cut a segment — can we monitor live mic levels and cut on silence?" Segmentation (VAD / silence-based) is therefore the central design problem, not an afterthought.

## Constraints and forces

- macOS-only, Apple Silicon. ffmpeg + avfoundation + whisper.cpp + Hammerspoon Lua only. No new runtime ([conventions.md][conventions-md] § Shell/Lua specifics). Streaming must not introduce Python/Node.
- The current `record`/`transcribe` split in [`dictate.sh`][dictate] is load-bearing and battle-tested: the bash-wrapper SIGINT-forwarding dance, the "exactly one SIGTERM" rule, and the WAV-trailer-flush-on-exit behaviour are all documented invariants with end-to-end tests (`bin/test-record-shutdown.sh`). A streaming design either *evolves* this (chunked, shape A) or *replaces* it (true streaming, shape B). Replacing it discards proven signal-handling code; flag the regression risk.
- Accuracy-first is the standing mandate. Whisper is an encoder-decoder transformer trained on **30-second** windows; cutting audio into short chunks throws away cross-segment context, fragments sentences, and — per research — raises WER and hallucination rates at boundaries. This is the core tension of the whole plan.
- The 200-line soft cap applies ([conventions.md][conventions-md] § File and function size). `dictate.sh` is ~100 lines; a streaming subcommand with VAD-boundary parsing is a distinct concern and a clean split trigger — it belongs in a sibling (e.g. `bin/stream.sh`) or a new `stream` subcommand that delegates to a helper, not inlined into `record`/`transcribe`.
- whisper.cpp tool availability is a hard dependency question. `whisper-cli` is confirmed present (it is what we use today). `whisper-stream` requires SDL2 and is an *example* target — whether the brew formula actually installs it into `bin/` is **unverified** and gates shape B entirely. See [Open questions][openq].
- **Hard conflict with the cursor-lock async-paste plan** ([2026-05-26-cursor-lock-async-paste.md][p-2a], Goal 2a). That plan defers a *single* paste to a *locked* field after the user has roamed away; streaming pastes *incrementally* into the *live* focused field. These are mutually exclusive at the paste layer. See [Conflict with cursor-lock async paste][conflict] for the arbitration proposal.

## Decisions

**D1 — Recommended architecture: (A) chunked segment-and-transcribe, NOT (B) true sliding-window streaming.**

Two architectural shapes were on the table:

- **(A) Chunked.** Keep ffmpeg recording continuously. Split the stream into segment WAVs at silence boundaries. Fire `whisper-cli` per *closed* segment. Paste each segment's text as it finalizes. Mostly reuses today's tools — `whisper-cli` is already our transcriber, ffmpeg is already our recorder.
- **(B) True streaming.** Pipe live mic audio into `whisper-stream` with a sliding window (`--step`/`--length`/`--keep`), consume incremental hypotheses as they emit. Lower latency, but partial hypotheses get *revised* as more audio arrives — "text already pasted, then corrected" becomes a paste-layer nightmare.

Choose **(A)**, for these reasons:

- **It reuses proven tooling.** `whisper-cli -nt -np` is exactly today's transcribe call; a chunk is just a shorter WAV. No dependency on `whisper-stream` being installed (see D2 and [Open questions][openq]). No SDL2.
- **It paste-finalizes, never retracts.** A chunk is only transcribed and pasted *after* its closing silence — the text is final, not a revisable hypothesis. This sidesteps the entire "paste-then-correct" problem that makes (B) hostile to a synthetic-keystroke paste model (you cannot un-type into an arbitrary app's text field; there is no reliable programmatic "select last N chars and replace").
- **It degrades to today's behaviour.** A single-segment utterance (the user speaks without pausing) is exactly record-then-transcribe — one chunk, one transcribe, one paste. Streaming is purely additive for multi-pause utterances; short utterances pay nothing.
- **It keeps the accuracy knobs in reach.** Per-chunk `whisper-cli` can take `--prompt` (prior chunk's text as context priming) and we control chunk length to respect the 30s window. (B) hides these inside the stream example's fixed window logic.

(B) stays documented as the rejected alternative and a future option *iff* `whisper-stream` proves installed and the revision problem gets a real answer (see [Open questions][openq]). It is genuinely lower-latency; it is rejected on paste-model incompatibility and dependency risk, not on latency.

**D2 — `whisper-stream` availability is a research gate; (A) does not depend on it.**

Research confirms the brew `whisper-cpp` formula builds with `-DWHISPER_SDL2=ON` and `-DWHISPER_BUILD_EXAMPLES=ON`, and the cmake install step installs built examples — so `whisper-stream` is *probably* present in `/opt/homebrew/bin`. But this is **not verified on the user's machine** and the formula's exact `bin.install` set is ambiguous from the formula source alone. The clean, cheap check is `ls /opt/homebrew/bin/whisper-stream` (and `whisper-server`, `vad-speech-segments`). Until that runs, treat `whisper-stream` as MAYBE-present. Choosing (A) means this gate does not block the plan — (A) needs only `whisper-cli`, which we already depend on. If a future revisit wants (B), this check moves from "nice to know" to "blocking dependency," and the [install bootstrapper][install-plan] would need to detect-or-build it (SDL2 adds a brew dep, build complexity, and install-time weight — flag against the bootstrapper's "seamless" goal).

**D3 — Recommended segmentation strategy: whisper.cpp's own Silero VAD as the chunker, with ffmpeg `silencedetect` as the fallback/cross-check.**

The user's question — "can we monitor live mic levels and cut on silence?" — has four candidate answers, compared:

- **whisper.cpp built-in Silero VAD (`--vad --vad-model`)** — recent whisper.cpp can run a Silero VAD model to detect speech regions and chunk internally, exposing `--vad-threshold`, `--vad-min-speech-duration-ms`, `--vad-min-silence-duration-ms`, `--vad-max-speech-duration-s`, and `--vad-samples-overlap`. This is a *learned* speech/non-speech classifier, far more robust to background noise than a raw level gate. **Recommended primary** because the tuning knobs map directly onto the segmentation problem (min-speech filters out coughs/clicks, min-silence is the hangover, max-speech-duration caps a runaway chunk under the 30s window, samples-overlap is the boundary-context mitigation).
- **ffmpeg `silencedetect`** — emits `silence_start`, `silence_end`, `silence_duration` to **stderr** (and as `lavfi.silence_*` frame metadata), parameterised by `noise=<dB>:d=<seconds>`. Parseable line-by-line as the recording runs. Simple, no model, already-installed. But it is a pure energy threshold: a noisy room, a fan, or keyboard clatter raises the floor and it cuts in the wrong places. **Recommended as the live "when to cut" trigger in the chunked pipeline** (it can run *during* recording on the live ffmpeg stream; Silero VAD via `whisper-cli` operates on a *finished* file), with Silero VAD applied per-chunk as the accuracy refinement.
- **ffmpeg `segment` muxer / `silenceremove`** — `segment` splits on fixed wall-clock boundaries (wrong — cuts mid-word); `silenceremove` strips silence rather than emitting boundaries. Neither gives "cut here because the user paused." Rejected as primary.
- **Live RMS / level monitoring (`astats` / `ebur128` / `volumedetect`)** — these report levels but are reporting/metering filters, not boundary emitters; reimplementing silence logic on top of their output duplicates what `silencedetect` already does. Rejected.

The practical recommendation is a **two-tier scheme**: ffmpeg `silencedetect` on the live stream decides *when to close a chunk* (it is the only option that works on a still-recording stream); each closed chunk is then transcribed by `whisper-cli`, optionally with `--vad` so Silero trims/validates the chunk's speech region for accuracy. This gets live cut decisions from ffmpeg and noise-robust transcription from Silero, using only already-installed tools.

**D4 — The segmentation tuning triad: silence threshold, minimum segment length, hangover. There is no universal setting.**

"Cut on silence" is three coupled parameters, and getting any one wrong degrades the result:

- **Silence threshold (`noise=<dB>`).** How quiet counts as silence. Too sensitive (e.g. `-50dB`) and a quiet room never registers as silence, so chunks never close (latency win lost). Too aggressive (`-30dB`) and it cuts on every inter-word micro-pause, fragmenting sentences and destroying whisper's context (accuracy lost). Mic, room, and gain all move this; it cannot be a single committed constant — it is a config key with a sane default and a documented "tune for your room" note.
- **Minimum segment length (`--vad-min-speech-duration-ms`).** Discards sub-threshold blips — a click, a breath, a single "um" — so we do not fire `whisper-cli` on 200ms of noise and paste garbage. Too high and short real words ("yes", "ναι") get dropped.
- **Hangover / minimum silence duration (`silencedetect` `d=` and `--vad-min-silence-duration-ms`).** How long silence must persist before we treat the pause as a true segment boundary rather than a breath between words. This is the single most important latency-vs-fragmentation dial: short hangover (~300ms) = snappy but choppy; long hangover (~800ms–1s) = coherent sentences but a visible lag before each chunk pastes. Natural Greek/English dictation pauses suggest a default around **600–700ms**; this is a guess that needs real-workload tuning (see [Open questions][openq]).

These become config keys (`STREAM_SILENCE_DB`, `STREAM_MIN_SEGMENT_MS`, `STREAM_HANGOVER_MS`) with defaults; the install bootstrapper does not need to prompt for them (advanced, edit-the-file like today's `THREADS`).

**D5 — Incremental paste: finalize-only, never retract. Paste each segment's text as it closes.**

The incremental-paste problem is: text lands in a live field while the user may still be speaking. Two sub-problems and the decisions:

- **Ordering.** Segments must paste in spoken order. Because (A) only pastes a chunk *after* it closes, and `whisper-cli` on a short chunk is fast, chunks normally finalize in order. But chunk N+1 can finish transcribing before chunk N if N is long — so paste must be **serialised through a queue**, not fired from each transcribe callback directly. A Lua-side ordered queue (segment index → text) drains in index order; a slow chunk N holds back N+1's paste until N lands. This is new state in the Lua module.
- **Retraction.** Rejected outright. We never paste a partial hypothesis we might revise (that is (B)'s problem, and we chose (A) specifically to avoid it). Each pasted chunk is final. The cost: no within-chunk correction once pasted — if whisper mis-hears the first chunk, it stays mis-heard. Acceptable, and identical to today's single-shot behaviour applied per-chunk.

Paste mechanism is unchanged from today — `hs.pasteboard.setContents` + synthetic `Cmd+V` — but now fires once per segment with a space/separator between segments. Clipboard clobber is now *repeated* (once per chunk), which makes the clipboard save/restore concern from the [cursor-lock plan][p-2a] D4 more acute, not less.

**D6 — Accept the accuracy cost; mitigate with overlap and prompt-priming, and bound the loss honestly.**

Cutting an utterance into chunks costs accuracy. Whisper is trained on 30s windows; per research, deviating from that — especially with short chunks — fragments sentences, loses cross-boundary context, and raises both WER and hallucination rates (hallucination notably rises when the model's chunking heuristics kick in). Two mitigations, both available with our chosen tools:

- **Boundary overlap.** Carry a small tail of the previous chunk into the next (`--vad-samples-overlap`, e.g. 100ms, or an explicit overlap window in the chunked WAV slicing) so boundary words are "heard twice." Reduces dropped/clipped words at cut points.
- **Prompt-priming.** Pass the *previous chunk's transcript* into the next chunk's `whisper-cli` via `--prompt`. This restores some of the lost left-context — whisper conditions its decoding on the prompt text, improving continuity of terminology and code-switching (directly relevant to this user's Greek+English technical dictation). Cheap to wire: keep the last chunk's clean text in Lua state, pass it down on the next `transcribe` call.

Even with both, expect streaming to be **measurably less accurate than today's single-pass** transcription of the same utterance. The honest framing: streaming wins on *perceived latency for long utterances*; it loses on *transcription quality* and is *neutral-to-worse for short utterances*. This must be stated in the README and is the core reason this is a *mode*, not a replacement (D7).

**D7 — Ship streaming as an opt-in mode, mutually exclusive with cursor-lock async paste. Default stays record-then-transcribe.**

Given the accuracy cost (D6) and the hard conflict with Goal 2a ([Conflict][conflict]), streaming is **not** the new default. It is a mode the user opts into (a config flag and/or a distinct hotkey), and it is mutually exclusive with cursor-lock async paste-back for a given utterance. The default — single-shot, accuracy-first, paste-into-focused-field — is preserved bit-for-bit, exactly as the v0.1 mandate requires. This also keeps the proven `record`/`transcribe` path as the always-available floor; streaming layers beside it, it does not rip it out.

## Sequence of work

This work has essentially no pure-function smoke surface beyond per-chunk transcription (which is just today's `transcribe` on a shorter WAV, already covered by `bin/test-transcribe-output.sh`). The segmentation + live-stream + ordered-paste logic is audio-I/O and Hammerspoon timing — per [conventions.md][conventions-md] § A4 and the v0.1 testing strategy, those ship with a **manual repro checklist** in the commit body, not an automated test.

1. **Settle the open questions that block coding** (this plan): verify `whisper-stream` presence (informational, since we chose A), pick the segmentation default triad, and get the product call on streaming-as-a-mode vs 2a arbitration.
2. **Spike segmentation in isolation.** A throwaway script: run `ffmpeg -f avfoundation -i :N -af silencedetect=noise=-35dB:d=0.6 -f null -` and watch `silence_start`/`silence_end` on stderr while speaking with deliberate pauses. Calibrate the threshold/hangover triad (D4) against the user's real mic and room *before* building any pipeline. This is the riskiest unknown; de-risk it first.
3. **CDE first for the new concern.** Add `bin/stream.sh` (or a `stream` subcommand delegating to a helper) with `@fileoverview` and a stub, plus a `bin/README.md` section describing what it owns, the segmentation contract, and the config keys (D4). No behaviour wired yet.
4. **Implement live chunking (shape A).** Recording ffmpeg stays as-is for capture; a parallel `silencedetect` read (or ffmpeg writing segment WAVs cut on silence) emits closed-chunk WAV paths. For each closed chunk, run the existing `whisper-cli` path (D1), with `--prompt` priming from the prior chunk and optional `--vad` (D3/D6). Preserve the one-SIGTERM / WAV-flush invariants for the final partial chunk on stop.
5. **Implement the Lua-side ordered paste queue (D5).** Segment index → text, drained in order; serialise paste so out-of-order transcribe completions still land in spoken order. New module state; keep the main module thin (sibling helper if it pushes the cap).
6. **Wire the mode switch (D7).** Config flag + (optionally) a distinct hotkey for streaming mode; ensure the default single-shot path is untouched and that streaming and cursor-lock async paste cannot both be active for one utterance.
7. **Accuracy + latency measurement.** On a real Greek+English workload, compare streaming vs single-shot: end-to-end perceived latency, and a rough WER/quality read on the same spoken passages. This is the go/no-go evidence for whether streaming is worth keeping on.
8. **Update docs** — `bin/README.md` (new subcommand, config keys, the accuracy-cost note), `hammerspoon/README.md` (mode switch, paste-queue behaviour, mutual exclusion with 2a).

## Conflict with cursor-lock async paste

This is the headline cross-plan tension and it is a **product decision, not an engineering one** — the [cursor-lock async-paste plan][p-2a] flags the same conflict from its side (its § "Interaction with in-flight sibling plans" and Open Question 5). Stating it plainly:

- **Streaming (this plan)** pastes *incrementally* into the *live, currently-focused* field as the user speaks. It only makes sense if the user is *watching the field fill in* — i.e. they have NOT roamed away.
- **Cursor-lock async paste (Goal 2a)** captures the insertion target at recording-stop (`Tend`), lets the user roam to other windows during transcription, and defers a *single* paste back to the *locked* field on completion.

You cannot do both for one utterance: streaming partial text into a field the user has navigated away from means yanking focus back repeatedly (hostile), and you cannot defer a single paste if you are emitting text continuously.

**Proposed arbitration (mutually exclusive modes):**

- **Streaming is valid only in the "stay focused" posture** — it composes with the cursor-lock plan's D6 fast path (captured app still frontmost = paste immediately, no settle delay). If the user stays in the field, streaming pastes live; if they roam, streaming has nowhere safe to paste.
- **Selecting streaming for an utterance disables cursor-lock async paste-back for that utterance** (and vice versa). Whichever mode the user is in is the mode that owns the paste layer.
- Concretely: a `cfg.streaming_mode` flag (and/or a dedicated streaming hotkey distinct from the async-paste hotkey) arbitrates. The two never run for the same recording. This matches the cursor-lock plan's own proposed resolution ("streaming is only valid in the stay-focused mode … cursor-lock async paste-back disables streaming for that utterance"). Since this plan is being written after that one, it accepts and names that dependency here.

**Interaction with the [cursor-loader plan][p-2c]** (Goal 2b): that plan's spinner means "working, please wait" — a discrete transcribe-then-done phase. Under streaming there is no such discrete phase; text flows continuously and the end is fuzzy. Per that plan's own § "Interaction with in-flight plans," the loader under streaming either (a) goes away (the streamed text *is* the feedback) or (b) becomes a subtle "still receiving" pulse that stops at end-of-stream. This plan agrees and owns that decision: in streaming mode, **the streamed text is the primary feedback**; the menubar `● REC` indicator stays (recording is still happening), and the cursor loader is suppressed or downgraded to a passive pulse. No conflict — just a mode-aware feedback choice, resolved here as the streaming plan owns the streaming-mode UX.

## Cross-doc effects

- [`bin/README.md`][bin-readme] — new `stream.sh` / `stream` subcommand section; new config keys (`STREAM_SILENCE_DB`, `STREAM_MIN_SEGMENT_MS`, `STREAM_HANGOVER_MS`, `STREAM_OVERLAP_MS`); the Size-budget note that the streaming concern has fired a split trigger; an explicit accuracy-cost caveat.
- [`dictate.sh`][dictate] header `@fileoverview` — if `stream` becomes a subcommand of `dictate.sh`, the subcommand list and the record/transcribe split narrative change. Prefer a sibling `stream.sh` to keep `dictate.sh` under cap.
- [`hammerspoon/README.md`][hs-readme] — mode-switch documentation, ordered-paste-queue behaviour, mutual exclusion with cursor-lock async paste, streaming-mode feedback (text-as-feedback, loader suppressed).
- [v0.1 spec][v01-spec] § Non-goals and § "Out of scope" — both name "Streaming / partial transcription" as deferred. The spec stays frozen as historical; this plan is the source of truth for the streaming contract going forward and explicitly reopens that non-goal as an opt-in mode (D7).
- [Cursor-lock async-paste plan][p-2a] — its Open Question 5 (mode arbitration with streaming) is *answered* by this plan's [Conflict][conflict] section (mutually exclusive modes). That plan need not change; this plan resolves the shared question.
- [Install bootstrapper plan][install-plan] — only if shape B is ever pursued: detecting/building `whisper-stream` (SDL2) would add an install dependency. Shape A (chosen) adds nothing the bootstrapper does not already handle. Flag, do not assume.
- `INVENTORY.md` and the plans switchboard — new `bin/stream.sh` (if created) and this plan need entries. **Out of scope for this plan to edit** — the orchestrator owns those switchboards.

## Risks

- **Accuracy regression is the headline risk.** Chunking deviates from whisper's 30s training window; research shows this raises WER and hallucination at boundaries. Overlap + prompt-priming (D6) mitigate but do not eliminate it. The go/no-go is the measurement in sequence step 7: if streaming's quality cost is large on the user's real Greek+English workload, the honest outcome is "keep it off by default, or drop it." Confidence that streaming beats today's UX is *moderate*, not high — it depends entirely on the latency-vs-accuracy preference for the user's actual utterance lengths.
- **Segmentation tuning is fragile and room-dependent.** The threshold/min-length/hangover triad (D4) has no universal setting; a noisy environment makes energy-based `silencedetect` cut in the wrong places. Mitigation: Silero VAD per-chunk (noise-robust) and the spike-first sequence (step 2) to calibrate on the real mic before building. Worst case: choppy, fragmented output that is worse than today.
- **Discarding proven signal-handling code (if shape B).** The one-SIGTERM / WAV-flush / bash-wrapper-forwarding invariants in [`record`][dictate] are tested and load-bearing. Shape A *keeps* them (recording ffmpeg is unchanged); shape B would replace them with `whisper-stream`'s own lifecycle. Another reason A is recommended — it does not throw away the hardest-won part of the current code.
- **`whisper-stream` dependency uncertainty (shape B only).** Unverified whether brew installs it; SDL2 build adds install weight. Shape A sidesteps this entirely. Flagged as a gate, not a blocker, because of the A choice.
- **Ordered-paste races.** Out-of-order transcribe completion (slow chunk N, fast chunk N+1) must be serialised (D5) or text pastes scrambled. New Lua state; a bug here corrupts word order — visible and annoying. Mitigation: explicit index-ordered queue, manual repro with a deliberately slow chunk.
- **Repeated clipboard clobber.** Per-segment paste clobbers the clipboard once per chunk, amplifying the cursor-lock plan's D4 clipboard concern. If both ship, streaming-mode paste must reuse that plan's save/restore wrapper.
- **Mode confusion.** Two paste behaviours (streaming live vs cursor-lock deferred) behind flags/hotkeys risks user confusion about "where will my text go." Mitigation: the mutual-exclusion arbitration (D7 / [Conflict][conflict]) and clear menubar/README signalling of the active mode.

## Open questions

These are unresolved and would materially change the implementation; flagged per [conventions.md][conventions-md] § "a plan is settled when it has no implicit open questions."

1. **Does the brew `whisper-cpp` formula actually install `whisper-stream` into `/opt/homebrew/bin`?** Research says the formula builds examples with SDL2 and installs built examples, which strongly implies yes — but the formula's exact `bin.install` set is ambiguous and this was **not verified on the user's machine** (the confirming `ls /opt/homebrew/bin/whisper-stream` was not run). Honest status: MAYBE. It does not gate shape A; it gates any future shape B.
2. **What is the right hangover (`STREAM_HANGOVER_MS`) for natural Greek+English dictation?** The latency-vs-fragmentation dial. Default guess ~600–700ms, but real pause distributions in this user's speech are unknown. Must be calibrated in the sequence step-2 spike, not assumed.
3. **Does prompt-priming (`--prompt` with prior chunk text) measurably help, or does it propagate errors forward?** Priming restores left-context but can also carry a mis-transcription into the next chunk's bias. Net effect on this user's code-switching workload is unverified — measure in step 7.
4. **Is streaming actually a win for this user's typical utterance length?** Streaming only beats today's UX for *long, multi-pause* utterances. If the user mostly dictates short bursts (a sentence at a time), today's single-shot is already ≤5s and *more accurate* — streaming would be strictly worse. This is the product question that decides whether the feature ships on by default, off by default, or at all.
5. **Should shape B (true `whisper-stream`) ever be revisited?** Only if (a) `whisper-stream` is confirmed installed, (b) the paste-then-revise problem gets a real answer (e.g. a per-app allowlist of fields where programmatic select-and-replace is reliable — which is exactly the AX-fragility the cursor-lock plan documents as unreliable), and (c) measured latency gains over shape A justify the dependency. Currently leaning never; documented so it is a decision, not an omission.
6. **Mode arbitration UX** — flag, dedicated hotkey, or both? D7 proposes mutual exclusion with cursor-lock async paste; the *surface* of the switch (how the user selects streaming) is a product call tied to how 2a exposes its own mode.

[v01-spec]: 2026-05-20-v0.1-spec.md
[p-2a]: 2026-05-26-cursor-lock-async-paste.md
[p-2c]: 2026-05-26-cursor-loader.md
[install-plan]: 2026-05-25-install-ux-bootstrap.md
[conventions-md]: ../conventions.md
[dictate]: ../../bin/dictate.sh
[bin-readme]: ../../bin/README.md
[lua]: ../../hammerspoon/voice-dictate.lua
[hs-readme]: ../../hammerspoon/README.md
[decisions]: #decisions
[risks]: #risks
[openq]: #open-questions
[conflict]: #conflict-with-cursor-lock-async-paste
