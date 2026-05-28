# hammerspoon — Lua module

Lua files loaded via the user's `~/.hammerspoon/init.lua` (which requires the main module). Own the macOS-side concerns: hotkeys, recording state, the menubar command center, paste, mic selection. Delegate audio capture and transcription to [bin/dictate.sh](../bin/dictate.sh) (single-shot) and [bin/stream.sh](../bin/stream.sh) (opt-in streaming).

- [voice-dictate.lua](voice-dictate.lua) — main entry. Hotkeys, state machine, single-shot recording, paste.
- [voice-dictate-menu.lua](voice-dictate-menu.lua) — menubar command center: the idle icon, the dropdown, the recording title, the spinner.
- [voice-dictate-mic.lua](voice-dictate-mic.lua) — mic picker. Scans avfoundation inputs, persists choice via `hs.settings`, builds the Microphone submenu.
- [voice-dictate-stream.lua](voice-dictate-stream.lua) — opt-in streaming mode: stdout consumer for `bin/stream.sh`. Stateless splice-wise; pairs with voice-dictate-splice.lua.
- [voice-dictate-splice.lua](voice-dictate-splice.lua) — clipboard-mediated splice paste layer. Per-emission `Shift+Cmd+Up` / `Cmd+X` / modify / `Cmd+V` with D3 divergence skip, D4 clipboard preservation, D6 focus-loss stop.
- [voice-dictate-stream-mode.lua](voice-dictate-stream-mode.lua) — orchestrator. Binds the streaming hotkey and composes stream + splice; the single-shot path in [voice-dictate.lua](voice-dictate.lua) is untouched.

All six files must live in `~/.hammerspoon/` so Lua's `require()` can resolve the siblings — `install.sh` symlinks every `hammerspoon/*.lua`.

## [voice-dictate.lua](voice-dictate.lua)

### Public API

```lua
local m = require("voice-dictate")
m.start()  -- bind hotkeys, mount the command center (idempotent — calls stop() first)
m.stop()   -- tear down everything (safe to call repeatedly; used by hs.reload)
```

The installer appends `require("voice-dictate").start()` to `init.lua`. Nothing else is needed.

### State machine

```
IDLE ──Cmd+Shift+D tap─► STREAMING ──Cmd+Shift+D tap─┐
                            │                         │
                            └─ Right Option release ──┴─► IDLE
```

Session state lives in [voice-dictate-stream-mode.lua](voice-dictate-stream-mode.lua); both hotkeys flip it via the same `startSession`/`stopSession` calls. Pressing the toggle while PTT-streaming (or vice versa) collapses to "stop": last hotkey wins. There is no separate "transcribing" state — emissions arrive continuously and paste live; release means stop.

### Why two hotkey mechanisms

- **Toggle** uses `hs.hotkey.bind` — the standard global hotkey API.
- **PTT** uses `hs.eventtap.new({flagsChanged}, …)` because Right Option is a modifier key, not a regular key. `hs.hotkey.bind` cannot capture modifier presses on their own.

The eventtap filters to `keycode == 61` (Right Option specifically) and uses the alt flag to distinguish press from release.

### Configurable values

Sourced from `~/.hammerspoon/voice-dictate-config.lua`, written by `install.sh`. Edit that file and run `hs.reload()` from the Hammerspoon Console to apply.

| Field | Default | Purpose |
|-------|---------|---------|
| `dictate_sh` | absolute path derived at install time | Single-shot shell entry point — kept for ad-hoc use; no hotkey reaches it. |
| `toggle_mods` | `{"cmd", "shift"}` | Modifiers for the toggle hotkey. |
| `toggle_key` | `"D"` | Key paired with the toggle modifiers. |
| `right_alt_keycode` | `61` | Filters the flagsChanged eventtap. Left Option is `58`. |
| `hide_hammerspoon_icon` | `true` | Hide Hammerspoon's own menu icon so the Dikta item is the sole control surface. Set `false` to keep it. |
| `stream_sh` | absolute path to `bin/stream.sh` (derived at install time) | Streaming shell entry point invoked by the orchestrator. |
| `stream_append_only` | `false` | Skip the splice substring-replace and just append the delta — Spike 1 fallback when whisper-stream emissions are non-revisable. |

### Failure modes

- **`stream.sh` exits non-zero** → log to the Hammerspoon Console, reset state to IDLE.
- **Focus leaves the field mid-session** → D6 self-stop fires: kill whisper-stream, restore the clipboard snapshot, no further pastes. User re-triggers explicitly.
- **`hs.task` start fails** → log error, state stays IDLE. Confirm `stream_sh` in `voice-dictate-config.lua` is executable.

### Reload safety

`M.start()` calls `M.stop()` first, so `hs.reload()` is always safe. Eventtaps, hotkeys, menubar item, and any in-flight streaming task are all torn down before re-binding. No accumulation across reloads.

## [voice-dictate-menu.lua](voice-dictate-menu.lua)

The menubar command center — the single control surface. `M.start()` hides Hammerspoon's own menu icon (config key `hide_hammerspoon_icon`, default true), so this dropdown also surfaces the two Hammerspoon functions that icon would otherwise provide.

### Dropdown

```
Dikta — Idle / Streaming…   (status header, disabled)
────────────
Start / Stop Dictation       ⌘⇧D
────────────
Microphone ▸                 (live-rescan mic picker submenu)
────────────
Open Console                 → hs.openConsole()
Reload Config                → hs.reload()
────────────
Show Hammerspoon Menu Icon   → hs.menuIcon(true)
```

Registered as a callback, so it re-reads streaming state and re-scans mics on every open. Driven by a control table injected from the main module (`onToggle`, `isStreaming`, `onOpenConsole`, `onReload`, `onShowHsIcon`, `hotkeyHint`, `hideHsIcon`) — no circular `require` back into the main module.

### Menubar states

- **Idle** — the Dikta spoken-mark, rendered in code via `hs.canvas` → `imageFromCanvas()` → `setIcon(image, true)` (template, so macOS auto-inverts for light/dark). Geometry mirrors [../brand/dikta-mark.svg](../brand/dikta-mark.svg). Falls back to the `○` text glyph if the canvas image fails.
- **Streaming** — `● LIVE` title, icon cleared.

### Hiding Hammerspoon's icon — recovery path

Hiding Hammerspoon's menu icon removes the usual access to its Console and Preferences. The dropdown's **Show Hammerspoon Menu Icon** restores it for the session, but `hs.reload()` re-hides it (the icon is re-asserted on every `M.start()`). To keep it permanently, set `hide_hammerspoon_icon = false` in `voice-dictate-config.lua`. If the module ever mounts but its own item disappears, re-enable the icon from Hammerspoon's Preferences (Spotlight → Hammerspoon) or run `hs.menuIcon(true)` in the Console.

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

CLAUDE.md's 200 soft / 300 hard line cap applies per file. The command-center extraction moved all menubar presentation out of the main module into [voice-dictate-menu.lua](voice-dictate-menu.lua), keeping each module under the cap. The opt-in streaming mode lives in its own sibling [voice-dictate-stream.lua](voice-dictate-stream.lua) for the same reason. Future split triggers: an on-pointer cursor loader or cursor-lock async paste would each justify another sibling.

## Streaming mode — voice-dictate-stream-mode.lua, voice-dictate-stream.lua, voice-dictate-splice.lua

Three siblings cooperate to deliver the opt-in streaming pipeline. The single-shot path in [voice-dictate.lua](voice-dictate.lua) is untouched — the two modes share no runtime state.

- [voice-dictate-stream.lua](voice-dictate-stream.lua) — stdout consumer. Spawns `bin/stream.sh` via `hs.task`, splits the line-delimited emissions, strips `[Start speaking]` markers, dispatches cleaned lines to a caller-registered emission handler. Knows nothing about pasting.
- [voice-dictate-splice.lua](voice-dictate-splice.lua) — the splice paste layer. Owns the per-emission keystroke chain, the D3 divergence skip, the D4 clipboard snapshot/restore, and the D6 focus-loss subscription.
- [voice-dictate-stream-mode.lua](voice-dictate-stream-mode.lua) — orchestrator. Binds the streaming hotkey; on tap, starts the splice session, registers `splice.applyEmission` as the stream's emission handler, and starts the stream. On second tap (or focus loss), unwinds in reverse.

### State machine

```
IDLE ──Cmd+Shift+S tap──► STREAMING ──Cmd+Shift+S tap──┐
                              │                          │
                              └─ focus loss / app exit ───┴─► IDLE (clipboard restored)
```

`STREAMING` means `whisper-stream` is alive and the splice layer has subscribed to its stdout. There is no separate "transcribing" state — emissions arrive continuously and are pasted as they arrive.

### The splice cycle

On every emission line from `bin/stream.sh`:

1. Build the new full dictation text from the committed prefix plus the latest emission.
2. Synthesize `Shift+Cmd+Up` (extend selection to start of document on native macOS text views).
3. Synthesize `Cmd+X` (cut selection to clipboard).
4. Read clipboard. Find the substring matching `last_pasted_dictation_text`. If absent (user edited mid-stream), restore the cut contents and skip — see Divergence-skip rule.
5. Replace the substring with the new full dictation text.
6. Write the modified string back to the clipboard.
7. Synthesize `Cmd+V`. Update `last_pasted_dictation_text`.

Cursor lands at end-of-paste — equivalent to live-typing. Pre-existing content before the dictation anchor is preserved (cut and re-pasted alongside our revision in the same `Cmd+V`); content after the cursor is never selected.

### Configurable values

The streaming-mode config keys are listed in the main "Configurable values" table for [voice-dictate.lua](voice-dictate.lua) above (`stream_sh`, `stream_toggle_mods`, `stream_toggle_key`, `stream_append_only`). All four are optional — modules fall back to defaults when keys are absent, so configs written before streaming landed continue to work without an install rerun.

### Divergence-skip rule (D3)

If the clipboard cut does not contain `last_pasted_dictation_text` as a substring, the user has edited our text manually. **Skip this emission**: write the cut contents back to the clipboard, paste, take no action on state. The user's edit is preserved; the model's revision is dropped for this cycle. The next emission tries again — if the model catches up to the user's intent, the splice resumes.

Exact substring match. No fuzzy matching, no recovery heuristics.

### Focus-loss policy (D6)

The module subscribes to `hs.window.filter` focus events. On focus loss — including app-switching, modal dialogs stealing input, or the user clicking into a different field — the streaming session **stops immediately**: kill `whisper-stream`, flush state, restore the pre-session clipboard snapshot, take no further paste actions. The user must re-trigger streaming after re-focusing. Better than guessing where to resume.

### Pasteboard preservation (D4)

`hs.pasteboard.getContents()` snapshots the system clipboard on streaming-session start. Splice operations use the general pasteboard (named pasteboards do not reliably interop with synthetic `Cmd+V` across all apps — confirmed in [Spike 2](../engineering/plans/2026-05-26-streaming-spike-log.md)). The snapshot is restored on session end. Mid-stream, the clipboard is unusable: if the user manually copies something while streaming is active, the next splice overwrites it. Documented limitation, mitigated by streaming being opt-in.

### Failure modes

- **`stream.sh` not found / model missing** → `hs.task` exit callback fires with a non-zero exit code; the module logs to the Console, notifies the user, and resets state to IDLE.
- **Focused app is on the blocklist** → the hotkey is a no-op for that utterance; the menubar dropdown surfaces the reason ("streaming disabled for this app").
- **Emission stream stalls** → state stays STREAMING; the user toggles off via the hotkey or the focus-loss policy stops it when they switch apps.
