# 2026-06-01 — Dikta rename: clean cut over the mic read-fallback

Owner: thanpolas. Status: settled. Supersedes [D3 of the rename plan][rename-plan] for the saved-mic migration only; the rest of that plan stands.

## Why this exists

The [rename plan][rename-plan] D3 mandated a *read-fallback* in the mic module: `loadAudioDevice()` would read the new `dikta.audioDevice` key, fall back to the old `voice-dictate.audioDevice` key, and write it forward once. That keeps a literal `voice-dictate` string alive in the codebase indefinitely.

The rename was executed under an explicit, emphasised user directive: **no mention of `voice-dictate` anywhere in the codebase.** A permanent fallback constant naming the old key contradicts that directive head-on. The two requirements cannot both hold, so this plan records which one wins and how the saved-mic state is protected without the fallback.

## Decision

**D1 — Clean cut in code.** The mic module reads and writes only `dikta.audioDevice`. No fallback to the old key, no migration constant, no `voice-dictate` literal anywhere in the source.

**D2 — Migrate the user's saved mic operationally, once, outside the repo.** The saved value lives in NSUserDefaults under the Hammerspoon app domain (`org.hammerspoon.Hammerspoon`), not in the repo. The one existing install (the author's iMac) had `:3` under the old key; it was copied forward to `dikta.audioDevice` with a single `defaults write` at rename time. The migration is a one-time operational act on live machine state, not code — so it carries no `voice-dictate` reference into the tree.

**D3 — No compatibility shim.** Per the rename plan's open question, the product is unpublished with no external users. The only stateful consumer was the author's own machine, handled by D2. A reset on any other unmigrated machine costs one mic re-selection from the menubar — acceptable for an unpublished tool.

## Consequence

Any machine that had a saved mic but is *not* migrated by the `defaults` copy falls back to the `:0` default device on first use after the rename and the user re-picks from the Microphone submenu once. This is the single user-affecting edge of the clean cut; it is bounded and self-healing.

[rename-plan]: 2026-05-26-rename-to-dikta.md
