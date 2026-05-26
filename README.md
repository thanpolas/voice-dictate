# voice-dictate

> Local hotkey-driven speech-to-text dictation for macOS. Greek-first, English-capable, fully offline via [whisper.cpp][whisper-cpp] + [Hammerspoon][hammerspoon].

[![Twitter Follow](https://img.shields.io/twitter/follow/thanpolas.svg?label=thanpolas&style=social)][twitter]

Press a hotkey, speak, release/tap — transcript pastes into the focused text field. No cloud, no monthly fee, no audio leaves the machine.

Two hotkeys:

- **Right Option (held)** — push-to-talk
- **Cmd+Shift+D (tap)** — toggle start/stop

# Prerequisites

macOS only — Hammerspoon is Mac-exclusive. Apple Silicon recommended; Intel works but transcription is materially slower.

| Dependency | Install |
|------------|---------|
| [whisper.cpp][whisper-cpp] CLI | `brew install whisper-cpp` |
| [ffmpeg][ffmpeg] | `brew install ffmpeg` |
| [Hammerspoon][hammerspoon] | `brew install --cask hammerspoon` |
| Whisper model | see [Model download](#model-download) below |

## Model download

Default model — `large-v3-turbo-q5_0` quantized, ~547 MB:

```bash
mkdir -p ~/whisper-models
curl -L --progress-bar \
  -o ~/whisper-models/ggml-large-v3-turbo-q5_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
```

Other Whisper checkpoints work — set `MODEL_PATH` to your preferred file. See the [v0.1 spec § Transcription][spec-transcription] for the reasoning behind the default.

# Install

```bash
git clone https://github.com/thanpolas/voice-dictate.git
cd voice-dictate
./install.sh
```

The installer verifies dependencies, symlinks the Hammerspoon module into `~/.hammerspoon/`, appends a `require()` line to `init.lua`, and triggers a Hammerspoon reload. macOS will prompt for **Accessibility**, **Microphone**, and **Input Monitoring** permissions on first hotkey use — grant all three under **System Settings → Privacy & Security**.

Detailed walkthrough, permissions troubleshooting, uninstall: [INSTALL.md][install-md].

# Usage

Click into any text field, then:

- Hold **Right Option**, speak, release → transcript pastes.
- Tap **Cmd+Shift+D**, speak, tap again → transcript pastes.

Menubar shows `● REC` while recording. System sounds play on start and stop.

To verify the shell side independently:

```bash
LANGUAGE=en ./bin/dictate.sh smoke
# → smoke: ok — And so, my fellow Americans, ...
```

If the smoke test passes but a hotkey doesn't paste, the issue is in Hammerspoon — check permissions and the Hammerspoon Console for errors.

# Configuration

`./install.sh` writes two local config files on first run. The committed code ships with no user-specific defaults.

- **`bin/config.local.sh`** — shell-side: `MODEL_PATH`, `LANGUAGE`, `THREADS`, `AUDIO_DEVICE`. Sourced by `dictate.sh` at run time. Per-invocation env overrides still work (e.g. `LANGUAGE=en ./bin/dictate.sh smoke`). Gitignored.
- **`~/.hammerspoon/voice-dictate-config.lua`** — Hammerspoon-side: absolute path to `dictate.sh`, toggle hotkey, PTT keycode, flush delay. Loaded via `require` on every Hammerspoon reload.

| Setting | File | Default |
|---------|------|---------|
| `MODEL_PATH` | `bin/config.local.sh` | `~/whisper-models/ggml-large-v3-turbo-q5_0.bin` (prompted at install) |
| `LANGUAGE` | `bin/config.local.sh` | `el` (Greek; use `auto` for detection, `en` for English-only) |
| `THREADS` | `bin/config.local.sh` | `8` |
| `AUDIO_DEVICE` | `bin/config.local.sh` | `:0` (macOS default mic) |
| `dictate_sh` | `~/.hammerspoon/voice-dictate-config.lua` | absolute path derived from your repo location at install |
| `toggle_mods` + `toggle_key` | `~/.hammerspoon/voice-dictate-config.lua` | `Cmd+Shift+D` |
| `right_alt_keycode` | `~/.hammerspoon/voice-dictate-config.lua` | `61` (Right Option; Left Option is `58`) |
| `flush_delay_s` | `~/.hammerspoon/voice-dictate-config.lua` | `0.2` |

The audio input device is picked at runtime via the menubar dropdown and persisted to `NSUserDefaults` (`hs.settings`); the `AUDIO_DEVICE` default above only applies when no device has been picked yet.

Edit either file and re-trigger:

- shell config: no reload needed; the next `dictate.sh` invocation picks it up.
- Hammerspoon config: run `hs.reload()` from the Console, or restart Hammerspoon.

Re-running `./install.sh` is safe — prompts pre-fill with your current values.

# Architecture

Two processes glued by Hammerspoon. The Lua module owns hotkeys, the state machine, the menubar item, and paste; `dictate.sh` owns audio capture (ffmpeg) and transcription (whisper-cli). Full design and the boundary contract live in the [v0.1 spec][spec-md].

# Engineering

This repo follows [Context-Driven Engineering][cde-md] — folder READMEs as the load-bearing architecture index.

- [CLAUDE.md][claude-md] — engineering entry point: hard rules, comments, markdown, commits.
- [INVENTORY.md][inventory-md] — master switchboard. Start here in any session.
- [engineering/][engineering] — settled rules in depth.

# Contributing

Issues and PRs welcome. Before opening a PR, skim [CLAUDE.md][claude-md] — file/function caps, comment style, Conventional Commits, reference-style markdown.

# License

Copyright © [Thanos Polychronakis][thanpolas] and Authors, [Licensed under ISC](LICENSE).

[whisper-cpp]: https://github.com/ggerganov/whisper.cpp
[ffmpeg]: https://ffmpeg.org/
[hammerspoon]: https://www.hammerspoon.org/
[install-md]: INSTALL.md
[dictate-sh]: bin/dictate.sh
[lua-mod]: hammerspoon/voice-dictate.lua
[spec-md]: engineering/plans/2026-05-20-v0.1-spec.md
[spec-transcription]: engineering/plans/2026-05-20-v0.1-spec.md#transcription
[cde-md]: engineering/cde.md
[claude-md]: CLAUDE.md
[inventory-md]: INVENTORY.md
[engineering]: engineering/
[thanpolas]: https://github.com/thanpolas
[twitter]: https://twitter.com/thanpolas
