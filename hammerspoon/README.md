# hammerspoon — Lua module

Single module loaded by the user's `~/.hammerspoon/init.lua`. Owns the macOS-side concerns: hotkeys, recording state, menubar, paste. Delegates audio capture and transcription to [bin/dictate.sh](../bin/dictate.sh).

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
- **`hs.task` start fails** → log error, state stays IDLE. Confirm `DICTATE_SH` is executable.

### Reload safety

`M.start()` calls `M.stop()` first, so `hs.reload()` is always safe. Eventtaps, hotkeys, menubar item, and any in-flight record task are all torn down before re-binding. No accumulation across reloads.

### Size budget

Soft cap 250 lines, currently ~180. Split triggers: visual feedback layer (canvas), per-app behavior, or English-dedicated hotkey would each justify a sibling file (`feedback.lua`, `routing.lua`).
