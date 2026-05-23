# Install

One-time setup. Assumes you already have [whisper.cpp][whisper-cpp], [Hammerspoon][hammerspoon], [ffmpeg][ffmpeg], and the model file in place — `install.sh` verifies all four and aborts cleanly if anything is missing.

## Prerequisites

```bash
brew install whisper-cpp ffmpeg
brew install --cask hammerspoon
```

Model — `large-v3-turbo-q5_0` quantized (547 MB):

```bash
mkdir -p ~/whisper-models
curl -L --progress-bar \
  -o ~/whisper-models/ggml-large-v3-turbo-q5_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
```

## Run the installer

```bash
cd ~/Projects/myStash/voice-dictate
./install.sh
```

What it does, in order:

1. Verifies `ffmpeg`, `whisper-cli`, and `/Applications/Hammerspoon.app`.
2. Prompts for your Whisper model path and default language. Pre-fills from any existing `bin/config.local.sh` on re-runs.
3. Writes `bin/config.local.sh` (gitignored) and `~/.hammerspoon/voice-dictate-config.lua` with the chosen values plus the technical defaults (threads, audio device, hotkey settings).
4. Symlinks `hammerspoon/voice-dictate.lua` into `~/.hammerspoon/voice-dictate.lua`.
5. Appends `require("voice-dictate").start()` to `~/.hammerspoon/init.lua` (idempotent — re-runs are safe).
6. Triggers `hammerspoon://reload` to apply without restarting the app.

## Grant macOS permissions

Hammerspoon prompts the first time each is needed. Approve all three in **System Settings → Privacy & Security**:

| Permission | Why |
|------------|-----|
| **Accessibility** | Required for the simulated `Cmd+V` paste (`hs.eventtap.keyStroke`). |
| **Microphone** | Required for `ffmpeg` to capture audio. Spawned by Hammerspoon → inherits TCC scope. |
| **Input Monitoring** | Required to capture the Right Option key globally for push-to-talk. |

If a hotkey fires but nothing happens, this is almost always the cause. Re-check Privacy & Security and toggle Hammerspoon off/on under each category.

## Verify

Open the Hammerspoon Console (menubar icon → **Console**). After a clean reload you should see:

```
voice-dictate: ready (PTT = Right Option, Toggle = Cmd+Shift+D)
```

Click into any text field and:

- Hold **Right Option**, speak, release → transcript pastes.
- Tap **Cmd+Shift+D**, speak, tap again → transcript pastes.

Menubar shows `● REC` while recording. System sounds play on start and stop.

## Smoke-test the shell side independently

If a hotkey path fails, isolate the shell side first:

```bash
LANGUAGE=en ~/Projects/myStash/voice-dictate/bin/dictate.sh smoke
# → smoke: ok — And so, my fellow Americans, ...
```

If `smoke` passes but the hotkey doesn't paste, the problem is in Hammerspoon (permissions, hotkey binding, or paste).

## Uninstall

```bash
rm ~/.hammerspoon/voice-dictate.lua
rm ~/.hammerspoon/voice-dictate-config.lua
# then edit ~/.hammerspoon/init.lua and remove the line:
#   require("voice-dictate").start()
open -g hammerspoon://reload
```

The cloned repo is untouched — delete it manually if you want it gone. Its `bin/config.local.sh` is gitignored and disappears with the repo.

[whisper-cpp]: https://github.com/ggerganov/whisper.cpp
[hammerspoon]: https://www.hammerspoon.org/
[ffmpeg]: https://ffmpeg.org/
