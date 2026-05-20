# voice-dictate

Local hotkey-driven speech-to-text dictation for macOS. Greek-first, English-capable, fully offline via [whisper.cpp][whisper-cpp] + [Hammerspoon][hammerspoon].

Two hotkeys:

- **Right Option (held)** — push-to-talk
- **Cmd+Shift+D (tap)** — toggle start/stop

Speak → release/tap → transcript pastes into the focused text field.

---

## Switchboard

- [SPEC.md](SPEC.md) — what we're building, scope, constraints, design decisions
- [PLAN.md](PLAN.md) — implementation steps with acceptance criteria
- [INSTALL.md](INSTALL.md) — one-shot install + macOS permissions walkthrough
- [bin/](bin/) — shell-side recorder and transcriber
- [hammerspoon/](hammerspoon/) — Lua module: hotkeys, state machine, paste

---

## Engineering

- [CLAUDE.md][claude-md] — engineering entry point: hard principles, CDE, comments, markdown, commits.
- [INVENTORY.md][inventory-md] — master switchboard. Start here in any session.
- [engineering/][engineering] — settled rules in depth: CDE definition, conventions, Lua and shell specifics.

[whisper-cpp]: https://github.com/ggerganov/whisper.cpp
[hammerspoon]: https://www.hammerspoon.org/
[claude-md]: CLAUDE.md
[inventory-md]: INVENTORY.md
[engineering]: engineering/
