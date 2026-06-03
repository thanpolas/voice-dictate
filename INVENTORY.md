# Dikta — Repository Inventory

Master switchboard. Authoritative root map of the repository. Every entry is one line, ≤180 chars, format `- [Title](path) — purpose hook.` Full rules: [engineering/cde.md](engineering/cde.md) under "Switchboard discipline".

## Root files

- [README.md](README.md) — Public-facing overview: prerequisites, install, usage, configuration, architecture, engineering, license.
- [CLAUDE.md](CLAUDE.md) — Engineering entry point: CDE, hard principles, comments, markdown, naming, commits.
- [INSTALL.md](INSTALL.md) — One-shot install, macOS permissions walkthrough, smoke-test path, uninstall.
- [install.sh](install.sh) — Idempotent installer: verifies deps, prompts for runtime config, writes the two local config files, symlinks both Lua modules, patches init.lua, reloads.
- [LICENSE](LICENSE) — ISC license: usage, modification, and distribution terms.
- [SECURITY.md](SECURITY.md) — Vulnerability reporting policy and supported versions.
- [.gitignore](.gitignore) — Ignored paths: macOS metadata and the local shell config written by install.sh.
- [.shellcheckrc](.shellcheckrc) — shellcheck project config: resolve `source` directives per-script so `shellcheck -x` works from any directory.

## [engineering/](engineering/)

Settled engineering rules. Folder switchboard: [engineering/README.md](engineering/README.md).

- [engineering/cde.md](engineering/cde.md) — Context-Driven Engineering definition, operating rule, switchboard discipline.
- [engineering/conventions.md](engineering/conventions.md) — File/function caps, naming, comments, markdown, commits, Lua and shell specifics.
- [engineering/plans/](engineering/plans/) — Dated plan documents and frozen v0.1 spec; folder switchboard: [engineering/plans/README.md](engineering/plans/README.md).

## [bin/](bin/)

Shell-side recorder and transcriber. Leaf README: [bin/README.md](bin/README.md).

- [bin/dikta.sh](bin/dikta.sh) — Single-shot record/transcribe (record, transcribe, smoke). Kept for ad-hoc shell use; no hotkey reaches it any more.
- [bin/stream.sh](bin/stream.sh) — Streaming recorder: long-running ffmpeg AVFoundation capture to a session WAV; spawned by Hammerspoon, signalled via SIGTERM at session end.
- [bin/stream-server.sh](bin/stream-server.sh) — Streaming inference daemon lifecycle (start/stop/status); keeps whisper-server loaded on loopback so per-tick inference pays no model-load tax.
- [bin/test-record-shutdown.sh](bin/test-record-shutdown.sh) — End-to-end test of record shutdown — SIGTERM forwarding, no orphan ffmpegs, WAV duration preserved.
- [bin/test-transcribe-output.sh](bin/test-transcribe-output.sh) — Regression test asserting `transcribe` output is free of ANSI escape bytes, direct and via `bash -c`.
- [bin/monitor-ghosts.sh](bin/monitor-ghosts.sh) — Background watchdog that logs ffmpeg-recording PID transitions to repo-local `tmp/ghost-watch.log`.

## [hammerspoon/](hammerspoon/)

Lua module loaded from the user's `~/.hammerspoon/init.lua`. Leaf README: [hammerspoon/README.md](hammerspoon/README.md).

- [hammerspoon/dikta.lua](hammerspoon/dikta.lua) — Hotkey handlers (PTT + toggle) driving streaming via dikta-stream-mode. Public API: `M.start()` / `M.stop()`.
- [hammerspoon/dikta-menu.lua](hammerspoon/dikta-menu.lua) — Menubar command center: idle icon, dropdown, `● LIVE` streaming title; hides Hammerspoon's icon.
- [hammerspoon/dikta-mic.lua](hammerspoon/dikta-mic.lua) — Mic picker: avfoundation device scan, Microphone submenu, NSUserDefaults persistence.
- [hammerspoon/dikta-stream.lua](hammerspoon/dikta-stream.lua) — Streaming pipeline lifecycle: spawns bin/stream.sh + bin/stream-server.sh, runs the ~2s poll timer, owns start/stop/state; drives dikta-stream-infer.
- [hammerspoon/dikta-stream-infer.lua](hammerspoon/dikta-stream-infer.lua) — Per-tick transcription: finalises a WAV snapshot, POSTs it to /inference, parses JSON, dedups, dispatches each transcript to the registered handler.
- [hammerspoon/dikta-ffmpeg.lua](hammerspoon/dikta-ffmpeg.lua) — ffmpeg-binary locator: cfg.ffmpeg_path wins, else probes the Homebrew prefixes. Shared by dikta-mic and the streaming pipeline.
- [hammerspoon/dikta-splice.lua](hammerspoon/dikta-splice.lua) — Clipboard-mediated splice paste layer; owns D3 divergence skip, D4 clipboard preservation, D6 focus-loss stop.
- [hammerspoon/dikta-stream-mode.lua](hammerspoon/dikta-stream-mode.lua) — Streaming session orchestrator; composes dikta-stream + dikta-splice into startSession/stopSession called from the main module's hotkeys.

## [brand/](brand/)

Dikta visual identity assets — collateral for docs and web, not loaded by the running tool. Leaf README: [brand/README.md](brand/README.md).

- [brand/README.md](brand/README.md) — Brand assets and usage: the spoken-mark, the Ink badge, the palette, and PNG regeneration.
- [brand/dikta-mark.svg](brand/dikta-mark.svg) — The Dikta spoken-mark (monochrome, transparent); source for dikta-mark.png.
- [brand/dikta-badge.svg](brand/dikta-badge.svg) — The mark on an Ink rounded-rect badge; source for dikta-badge.png.

## [install/](install/)

Bootstrapper helpers sourced by the top-level `install.sh`. Stubs today; behaviour lands per the dated plan. Folder switchboard: [install/README.md](install/README.md).

- [install/lib.sh](install/lib.sh) — Shared interactive prompt, logging, and command-presence helpers used by every other install helper.
- [install/deps.sh](install/deps.sh) — Homebrew detection and bootstrap; per-dependency install prompts; brew install dispatch.
- [install/model.sh](install/model.sh) — Whisper model discovery across known locations and resumable download to project-local storage.
- [install/hammerspoon.sh](install/hammerspoon.sh) — Symlink the Lua modules, patch the user's init script, and trigger a Hammerspoon reload.
- [install/config.sh](install/config.sh) — Generate the shell-side and Lua-side runtime configuration files from prompted values.
- [install/migration.sh](install/migration.sh) — Version-to-version migration entry point invoked by the orchestrator's update flow.

## [.github/](.github/)

GitHub-specific metadata. Not loaded by the running tool.

- [.github/FUNDING.yml](.github/FUNDING.yml) — GitHub Sponsors button configuration shown on the repo page.

## [.claude/](.claude/)

Claude Code configuration for editing sessions. Not loaded by the running tool — only by the harness when this repo is opened in Claude Code.
