# 2026-06-01 — Splice loses every revision after the first

Owner: thanpolas. Status: diagnosing. Sibling concern to [the flush-cadence plan][flush-plan] (that one is about *when* transcripts arrive; this one is about *whether they get pasted*).

## Symptom

Real session 2026-06-01 00:53. The pipeline transcribed and emitted correctly — the Hammerspoon Console shows the full transcript growing across five `[vd-stream] emit:` lines and a final `finalize emit:`. Yet only the **first** emission ("Ωραία θέλω τώρα να μου πεις") landed in the field; every later revision was lost.

So the fault is **not** capture or transcription — both are healthy. It is the paste layer: [`voice-dictate-splice.lua`][splice].

## Root cause (high-confidence, from the code + log; not yet confirmed by splice-side logs)

[`spliceCycle`][splice] has two paths:

- **First emission** (`lastPastedDictationText == ""`): skips the keystroke dance and pastes at the cursor. Works — hence the first chunk landed.
- **Later emissions**: runs [`selectToStart()`][splice] = **Shift+Cmd+Up**, then Cmd+X, then looks for the previously-pasted text in the cut clipboard. If absent → **D3 divergence-skip**: re-paste the cut, drop the revision.

The cycle's own docstring already admits Shift+Cmd+Up does **not** mean "select to document start" in Claude Code's input and most REPLs — that is *why* the first emission skips it. But the later-emission path still relies on it. In those apps the select/cut never yields the anchor, so **D3 skip fires on every revision** and the field freezes at the first paste. The dictated content in the failing session ("…τοπικό αντίγραφο σε συγχρονισμό… τον φάκελο… engineering principles") was being typed into Claude Code's own input — exactly the surface the docstring flags.

## Step 1 — confirm with logging (done)

The splice layer had **zero** `print` output, so the failing branch was invisible. Added `[vd-splice]` diagnostics to [`spliceCycle`][splice]: `first paste`, `landed`, and `D3 skip` (with the cut length + leading chars). Behaviour unchanged. Next session's Console will show whether D3 skip fires on every revision as predicted. Requires `hs.reload()` to take effect.

## Proposed fix (not started — waits on Step 1 confirmation)

Replace the app-dependent "select to document start" anchor with an app-agnostic one: the splice always appends trailing content and the cursor sits at the end, so deleting exactly `#lastPastedDictationText` characters backward (e.g. Shift+Left ×N then replace, or N× delete) targets precisely our own prior paste without relying on Shift+Cmd+Up semantics. Confirm against the Spike 2 target list before shipping. Opens its own implementation section here once Step 1 confirms the diagnosis.

## Out of scope

The ~8s transcript cadence — that is the [flush-cadence plan][flush-plan]'s problem, currently blocked.

[flush-plan]: 2026-05-31-streaming-flush-cadence.md
[splice]: ../../hammerspoon/voice-dictate-splice.lua
