# hammerspoon — Lua module

Two Lua files loaded by the user's `~/.hammerspoon/init.lua`. Own the macOS-side concerns: hotkeys, recording state, menubar, paste, mic selection. Delegate audio capture and transcription to [bin/dictate.sh](../bin/dictate.sh).

- [voice-dictate.lua](voice-dictate.lua) — main entry. Hotkeys, state machine, menubar, paste.
- [voice-dictate-mic.lua](voice-dictate-mic.lua) — mic picker. Scans avfoundation inputs, persists choice via `hs.settings`, builds the menubar dropdown.

Both files must live in `~/.hammerspoon/` so Lua's `require()` can resolve the sibling — `install.sh` symlinks both.

## [voice-dictate.lua](voice-dictate.lua)

### Public API

```lua
local m = require("voice-dictate")
m.start()  -- bind hotkeys, mount menubar (idempotent — calls stop() first)
m.stop()   -- tear down everything (safe to call repeatedly; used by hs.reload)
```

The installer appends `require("voice-dictate").start()` to `init.lua`. Nothing else is needed.

### State machine

```
IDLE ──Cmd+Shift+D tap─► RECORDING ──Cmd+Shift+D tap─┐
                            │                         │
                            └─ Right Option release ──┴─► TRANSCRIBING ─► IDLE
```

One state variable (`recording`) is shared by both hotkeys. Pressing the toggle while PTT-recording (or vice versa) collapses to "stop": last hotkey wins. Acceptable for v0.1.

### Why two hotkey mechanisms

- **Toggle** uses `hs.hotkey.bind` — the standard global hotkey API.
- **PTT** uses `hs.eventtap.new({flagsChanged}, …)` because Right Option is a modifier key, not a regular key. `hs.hotkey.bind` cannot capture modifier presses on their own.

The eventtap filters to `keycode == 61` (Right Option specifically) and uses the alt flag to distinguish press from release.

### Configurable values

Sourced from `~/.hammerspoon/voice-dictate-config.lua`, written by `install.sh`. Edit that file and run `hs.reload()` from the Hammerspoon Console to apply.

| Field | Default | Purpose |
|-------|---------|---------|
| `dictate_sh` | absolute path derived at install time | Path to the shell entry point. |
| `toggle_mods` | `{"cmd", "shift"}` | Modifiers for the toggle hotkey. |
| `toggle_key` | `"D"` | Key paired with the toggle modifiers. |
| `right_alt_keycode` | `61` | Filters the flagsChanged eventtap. Left Option is `58`. |
| `flush_delay_s` | `0.2` | Delay after SIGTERM before reading the WAV. Bump if recordings look truncated. |

### Failure modes

- **Transcript empty** → `hs.notify` toast + log to Hammerspoon Console. No paste fired. State resets clean.
- **`dictate.sh` not found** → `hs.execute` returns nil; transcript empty path triggers.
- **`hs.task` start fails** → log error, state stays IDLE. Confirm `dictate_sh` in `voice-dictate-config.lua` is executable.

### Reload safety

`M.start()` calls `M.stop()` first, so `hs.reload()` is always safe. Eventtaps, hotkeys, menubar item, and any in-flight record task are all torn down before re-binding. No accumulation across reloads.

## [voice-dictate-mic.lua](voice-dictate-mic.lua)

Sibling module owning the mic picker. `require`d by the main module; not loaded by `init.lua` directly.

### Public API

```lua
local mic = require("voice-dictate-mic")
mic.loadAudioDevice()  -- returns ":N" — last-selected index, falls back to ":0"
mic.buildMicMenu()     -- builds menu items for hs.menubar:setMenu(); rescans on each call
```

### Behaviour

- **Scan on every open.** `hs.menubar:setMenu(mic.buildMicMenu)` registers the function as a callback; Hammerspoon invokes it on each click, so the device list reflects current plug/unplug state of USB and Bluetooth devices.
- **Scan cost ~0.5s.** ffmpeg is shelled out synchronously; the menu briefly hangs while it runs. Acceptable for an occasional click; if it becomes annoying, cache results for a few seconds.
- **Persistence via `hs.settings`.** Selection is stored under the key `voice-dictate.audioDevice` in NSUserDefaults. Survives reloads and reboots without a config file.
- **Passthrough to dictate.sh.** The main module reads `mic.loadAudioDevice()` at the start of every recording and passes it as `AUDIO_DEVICE=…` via `/usr/bin/env`, so changing mics takes effect on the next utterance.

### Failure modes

- **No audio devices found** → menu shows a disabled "no audio devices found" line. Recording falls back to `:0` and likely produces a zero-byte WAV → empty transcript → notify path.
- **ffmpeg not at `/opt/homebrew/bin/ffmpeg`** → scan returns empty; same handling as above. The path is hardcoded because Hammerspoon launches from launchd with a minimal `PATH`.

### Size budget

Both files soft-capped at 250 lines per file (CLAUDE.md's 200 soft / 300 hard applies). Main module currently ~210, mic ~95. Future split triggers: visual feedback layer (canvas), per-app behavior, or English-dedicated hotkey would each justify another sibling file.
