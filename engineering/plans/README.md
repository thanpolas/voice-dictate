# plans — switchboard

Dated planning documents. Each plan owns one body of work — its goal, decisions, open questions, and sequence — and stays in the tree as the durable record once the work ships. Plans are written ahead of implementation per [conventions.md][conventions-md] § Spec → Plan → Implement; the locked v0.1 spec also lives here as a frozen reference.

Naming: `YYYY-MM-DD-slug.md`. The date is the day the plan was opened, not when the work landed.

## Contents

- [2026-05-26-menubar-command-center.md](2026-05-26-menubar-command-center.md) — Turn the custom menubar item into the single command center and hide Hammerspoon's own icon.
- [2026-05-26-branding-identity.md](2026-05-26-branding-identity.md) — Settle the published name and visual identity, plus a code-rendered monochrome menubar mark.
- [2026-05-26-rename-to-dikta.md](2026-05-26-rename-to-dikta.md) — Mechanical rename of voice-dictate to Dikta across modules, config, and docs, with a saved-mic migration.
- [2026-05-26-cursor-lock-async-paste.md](2026-05-26-cursor-lock-async-paste.md) — Lock the focused field at recording end; paste the transcript back there after switching windows.
- [2026-05-26-cursor-loader.md](2026-05-26-cursor-loader.md) — On-pointer visual feedback during transcription: a decorative spinner overlay tracking the mouse cursor.
- [2026-05-26-streaming-transcription.md](2026-05-26-streaming-transcription.md) — Transcribe audio in segments while recording continues, cutting on silence at pauses.
- [2026-05-26-streaming-spike-log.md](2026-05-26-streaming-spike-log.md) — Findings from the two calibration spikes the streaming-transcription plan calls for; informs production defaults and fallbacks.
- [2026-05-25-install-ux-bootstrap.md](2026-05-25-install-ux-bootstrap.md) — Install UX rethink: delete INSTALL.md, make install.sh a true bootstrapper, decide distribution path.
- [2026-05-20-v0.1-spec.md](2026-05-20-v0.1-spec.md) — Locked v0.1 spec: scope, architecture, configuration surface, dependencies, open questions.
- [2026-05-20-v0.1-implementation.md](2026-05-20-v0.1-implementation.md) — Original v0.1 implementation order: dictate.sh → Lua module → install.sh → READMEs → e2e.

[conventions-md]: ../conventions.md
