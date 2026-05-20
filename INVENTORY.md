# voice-dictate — Repository Inventory

Master switchboard. Authoritative root map of the repository. Every entry is one line, ≤180 chars, format `- [Title](path) — purpose hook.` Full rules: [engineering/cde.md](engineering/cde.md) under "Switchboard discipline".

## Root files

- [README.md](README.md) — Orientation: what voice-dictate is, the two hotkeys, switchboard links.
- [CLAUDE.md](CLAUDE.md) — Engineering entry point: CDE, hard principles, comments, markdown, naming, commits.
- [SPEC.md](SPEC.md) — Locked v0.1 scope, architecture, configuration surface, dependencies, open questions.
- [PLAN.md](PLAN.md) — Implementation steps with acceptance criteria and current status.
- [INSTALL.md](INSTALL.md) — One-shot install, macOS permissions walkthrough, smoke-test path, uninstall.
- [install.sh](install.sh) — Idempotent installer: verifies deps, symlinks the Lua module, patches init.lua, reloads.

## [engineering/](engineering/)

Settled engineering rules. Folder switchboard: [engineering/README.md](engineering/README.md).

- [engineering/cde.md](engineering/cde.md) — Context-Driven Engineering definition, operating rule, switchboard discipline.
- [engineering/conventions.md](engineering/conventions.md) — File/function caps, naming, comments, markdown, commits, Lua and shell specifics.

## [bin/](bin/)

Shell-side recorder and transcriber. Leaf README: [bin/README.md](bin/README.md).

- [bin/dictate.sh](bin/dictate.sh) — Three subcommands (record, transcribe, smoke). Spawned by Hammerspoon; standalone-runnable.

## [hammerspoon/](hammerspoon/)

Lua module loaded from the user's `~/.hammerspoon/init.lua`. Leaf README: [hammerspoon/README.md](hammerspoon/README.md).

- [hammerspoon/voice-dictate.lua](hammerspoon/voice-dictate.lua) — Hotkey handlers, state machine, menubar, paste. Public API: `M.start()` / `M.stop()`.

## [.claude/](.claude/)

Claude Code configuration for editing sessions. Not loaded by the running tool — only by the harness when this repo is opened in Claude Code.
