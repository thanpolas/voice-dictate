# hammerspoon — Lua module

Lua files loaded via the user's `~/.hammerspoon/init.lua` (which requires the main module). Own the macOS-side concerns: hotkeys, recording state, the menubar command center, paste, mic selection. Delegate audio capture and transcription to [bin/dikta.sh](../bin/dikta.sh) (single-shot) and [bin/stream.sh](../bin/stream.sh) (opt-in streaming).

- [dikta.lua](dikta.lua) — main entry. Hotkeys, state machine, single-shot recording, paste.
- [dikta-menu.lua](dikta-menu.lua) — menubar command center: the idle icon, the dropdown, the recording title, the spinner.
- [dikta-mic.lua](dikta-mic.lua) — mic picker. Scans avfoundation inputs, persists choice via `hs.settings`, builds the Microphone submenu.
- [dikta-stream.lua](dikta-stream.lua) — streaming pipeline orchestrator: spawns `bin/stream.sh` + `bin/stream-server.sh`, runs an `hs.timer` every ~2s to POST a WAV snapshot and dispatch the JSON transcript to the registered emission handler. Stateless splice-wise; pairs with dikta-splice.lua.
- [dikta-splice.lua](dikta-splice.lua) — clipboard-mediated splice paste layer. Per-emission `Shift+Cmd+Up` / `Cmd+X` / modify / `Cmd+V` with D3 divergence skip, D4 clipboard preservation, D6 focus-loss stop.
- [dikta-stream-mode.lua](dikta-stream-mode.lua) — session orchestrator. Composes dikta-stream (pipeline) + dikta-splice (paste) into start/stop calls driven by the main module's hotkeys.

All six files must live in `~/.hammerspoon/` so Lua's `require()` can resolve the siblings — `install.sh` symlinks every `hammerspoon/*.lua`.

## [dikta.lua](dikta.lua)

### Public API

```lua
local m = require("dikta")
m.start()  -- bind hotkeys, mount the command center (idempotent — calls stop() first)
m.stop()   -- tear down everything (safe to call repeatedly; used by hs.reload)
```

The installer appends `require("dikta").start()` to `init.lua`. Nothing else is needed.

### State machine

```
IDLE ──Cmd+Shift+D tap─► STREAMING ──Cmd+Shift+D tap──────┐
                            │                              │
                            ├─ Right Option release ───────┤
                            ├─ any ordinary keystroke ─────┤
                            └─ focus loss ─────────────────┴─► IDLE
```

Session state lives in [dikta-stream-mode.lua](dikta-stream-mode.lua); both hotkeys flip it via the same `startSession`/`stopSession` calls. Pressing the toggle while PTT-streaming (or vice versa) collapses to "stop": last hotkey wins. There is no separate "transcribing" state — emissions arrive continuously and paste live; release means stop.

Four triggers stop an active session, all "stop and keep" (the transcript pasted so far stays, the clipboard is restored): a second toggle tap, Right Option release, **any ordinary keystroke**, and focus loss. The keystroke trigger lets the user just start typing to take over — see [the keypress-stop plan](../engineering/plans/2026-05-31-keypress-stop.md). "Ordinary" means a `keyDown` carrying no Cmd/Ctrl/Alt; that same filter excludes the splice layer's own synthetic `Cmd+X` / `Cmd+V` / `Shift+Cmd+Up` keystrokes, so the session never self-cancels.

### Why two hotkey mechanisms

- **Toggle** uses `hs.hotkey.bind` — the standard global hotkey API.
- **PTT** uses `hs.eventtap.new({flagsChanged}, …)` because Right Option is a modifier key, not a regular key. `hs.hotkey.bind` cannot capture modifier presses on their own.

The eventtap filters to `keycode == 61` (Right Option specifically) and uses the alt flag to distinguish press from release.

A third, always-on `keyDown` eventtap implements the keystroke-stop trigger (above). It is observational — it returns `false` so the keystroke passes through to the field — and its handler no-ops unless a session is active. Like the PTT tap, it is created in `bindHotkeys` and torn down in `unbindHotkeys`, so `hs.reload()` never leaks one.

### Configurable values

Sourced from `~/.hammerspoon/dikta-config.lua`, written by `install.sh`. Edit that file and run `hs.reload()` from the Hammerspoon Console to apply.

| Field | Default | Purpose |
|-------|---------|---------|
| `dikta_sh` | absolute path derived at install time | Single-shot shell entry point — kept for ad-hoc use; no hotkey reaches it. |
| `toggle_mods` | `{"cmd", "shift"}` | Modifiers for the toggle hotkey. |
| `toggle_key` | `"D"` | Key paired with the toggle modifiers. |
| `right_alt_keycode` | `61` | Filters the flagsChanged eventtap. Left Option is `58`. |
| `hide_hammerspoon_icon` | `true` | Hide Hammerspoon's own menu icon so the Dikta item is the sole control surface. Set `false` to keep it. |
| `stream_sh` | absolute path to `bin/stream.sh` (derived at install time) | ffmpeg recorder script invoked by the streaming orchestrator. |
| `server_sh` | absolute path to `bin/stream-server.sh` (derived at install time) | whisper-server lifecycle helper invoked by the streaming orchestrator. |

### Failure modes

- **`stream.sh` or `stream-server.sh` exits non-zero** → log to the Hammerspoon Console, reset state to IDLE.
- **Focus leaves the field mid-session** → D6 self-stop fires: tear down the pipeline, restore the clipboard snapshot, no further pastes. User re-triggers explicitly.
- **`hs.task` start fails** → log error, state stays IDLE. Confirm `stream_sh` / `server_sh` in `dikta-config.lua` are executable.

### Reload safety

`M.start()` calls `M.stop()` first, so `hs.reload()` is always safe. Eventtaps, hotkeys, menubar item, and any in-flight streaming task are all torn down before re-binding. No accumulation across reloads.

## [dikta-menu.lua](dikta-menu.lua)

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

Hiding Hammerspoon's menu icon removes the usual access to its Console and Preferences. The dropdown's **Show Hammerspoon Menu Icon** restores it for the session, but `hs.reload()` re-hides it (the icon is re-asserted on every `M.start()`). To keep it permanently, set `hide_hammerspoon_icon = false` in `dikta-config.lua`. If the module ever mounts but its own item disappears, re-enable the icon from Hammerspoon's Preferences (Spotlight → Hammerspoon) or run `hs.menuIcon(true)` in the Console.

## [dikta-mic.lua](dikta-mic.lua)

Sibling module owning the mic picker. `require`d by the main module; not loaded by `init.lua` directly.

### Public API

```lua
local mic = require("dikta-mic")
mic.loadAudioDevice()  -- returns ":N" — last-selected index, falls back to ":0"
mic.buildMicMenu()     -- builds menu items for hs.menubar:setMenu(); rescans on each call
```

### Behaviour

- **Scan on every open.** `hs.menubar:setMenu(mic.buildMicMenu)` registers the function as a callback; Hammerspoon invokes it on each click, so the device list reflects current plug/unplug state of USB and Bluetooth devices.
- **Scan cost ~0.5s.** ffmpeg is shelled out synchronously; the menu briefly hangs while it runs. Acceptable for an occasional click; if it becomes annoying, cache results for a few seconds.
- **Persistence via `hs.settings`.** Selection is stored under the key `dikta.audioDevice` in NSUserDefaults. Survives reloads and reboots without a config file.
- **Passthrough to dikta.sh.** The main module reads `mic.loadAudioDevice()` at the start of every recording and passes it as `AUDIO_DEVICE=…` via `/usr/bin/env`, so changing mics takes effect on the next utterance.

### Failure modes

- **No audio devices found** → menu shows a disabled "no audio devices found" line. Recording falls back to `:0` and likely produces a zero-byte WAV → empty transcript → notify path.
- **ffmpeg binary missing or moved** → scan returns empty; same handling as above. The path is resolved at install time by `install.sh` (via `command -v ffmpeg`) and written into `dikta-config.lua` as `ffmpeg_path`; both this module and [dikta-stream.lua](dikta-stream.lua) read that key. If the Lua-side config predates the key, both modules fall back to probing `/opt/homebrew/bin/ffmpeg` and `/usr/local/bin/ffmpeg` and log a one-line warning suggesting a re-install.

### Size budget

CLAUDE.md's 200 soft / 300 hard line cap applies per file. The command-center extraction moved all menubar presentation out of the main module into [dikta-menu.lua](dikta-menu.lua), keeping each module under the cap. The opt-in streaming mode lives in its own sibling [dikta-stream.lua](dikta-stream.lua) for the same reason. Future split triggers: an on-pointer cursor loader or cursor-lock async paste would each justify another sibling.

## Streaming mode — dikta-stream-mode.lua, dikta-stream.lua, dikta-splice.lua

Three siblings cooperate to deliver the streaming pipeline that the PTT and toggle hotkeys both drive.

- [dikta-stream.lua](dikta-stream.lua) — pipeline orchestrator. Spawns `bin/stream-server.sh start` (whisper-server daemon) and `bin/stream.sh record` (long-running ffmpeg) via `hs.task`, then runs an `hs.timer` every ~2s that finalises an ffmpeg snapshot of the in-progress session WAV, POSTs the snapshot to the daemon's `/inference` endpoint, parses the JSON, and dispatches the full transcript as a single emission. Knows nothing about pasting.
- [dikta-splice.lua](dikta-splice.lua) — the splice paste layer. Owns the per-emission keystroke chain, the D3 divergence skip, the D4 clipboard snapshot/restore, and the D6 focus-loss subscription.
- [dikta-stream-mode.lua](dikta-stream-mode.lua) — session orchestrator. On `startSession`, starts the splice session, registers `splice.applyEmission` as the stream's emission handler, and starts the pipeline. On `stopSession` (second hotkey tap, or focus loss), unwinds in reverse.

### State machine

```
IDLE ──Cmd+Shift+D tap──► STREAMING ──Cmd+Shift+D tap───────┐
                              │                              │
                              ├─ any ordinary keystroke ─────┤
                              └─ focus loss / app exit ──────┴─► IDLE (clipboard restored)
```

`STREAMING` means the whisper-server daemon and ffmpeg recorder are alive, the timer is polling, and the splice layer is subscribed to the resulting emissions. There is no separate "transcribing" state — emissions arrive every poll tick and paste live.

### The splice cycle

On every emission dispatched from the pipeline:

1. Build the new full dictation text from the committed prefix plus the latest emission.
2. Synthesize `Shift+Cmd+Up` (extend selection to start of document on native macOS text views).
3. Synthesize `Cmd+X` (cut selection to clipboard).
4. Read clipboard. Find the substring matching `last_pasted_dictation_text`. If absent (user edited mid-stream), restore the cut contents and skip — see Divergence-skip rule.
5. Replace the substring with the new full dictation text.
6. Write the modified string back to the clipboard.
7. Synthesize `Cmd+V`. Update `last_pasted_dictation_text`.

Cursor lands at end-of-paste — equivalent to live-typing. Pre-existing content before the dictation anchor is preserved (cut and re-pasted alongside our revision in the same `Cmd+V`); content after the cursor is never selected.

### Configurable values

The streaming-mode config keys are listed in the main "Configurable values" table for [dikta.lua](dikta.lua) above (`stream_sh`, `server_sh`). Both are optional — the Lua module falls back to repo-derived defaults when keys are absent, so older configs continue to load without an install rerun.

### Divergence-skip rule (D3)

If the clipboard cut does not contain `last_pasted_dictation_text` as a substring, the user has edited our text manually. **Skip this emission**: write the cut contents back to the clipboard, paste, take no action on state. The user's edit is preserved; the model's revision is dropped for this cycle. The next emission tries again — if the model catches up to the user's intent, the splice resumes.

Exact substring match. No fuzzy matching, no recovery heuristics.

### Focus-loss policy (D6)

The module subscribes to `hs.window.filter` focus events. On focus loss — including app-switching, modal dialogs stealing input, or the user clicking into a different field — the streaming session **stops immediately**: tear down the pipeline, flush state, restore the pre-session clipboard snapshot, take no further paste actions. The user must re-trigger streaming after re-focusing. Better than guessing where to resume.

### Pasteboard preservation (D4)

`hs.pasteboard.getContents()` snapshots the system clipboard on streaming-session start. Splice operations use the general pasteboard (named pasteboards do not reliably interop with synthetic `Cmd+V` across all apps — confirmed in [Spike 2](../engineering/plans/2026-05-26-streaming-spike-log.md)). The snapshot is restored on session end. Mid-stream, the clipboard is unusable: if the user manually copies something while streaming is active, the next splice overwrites it. Documented limitation, mitigated by streaming being opt-in.

### Failure modes

- **`stream.sh` / `stream-server.sh` not found, or model missing** → `hs.task` exit callback fires with a non-zero exit code; the module logs to the Console, notifies the user, and resets state to IDLE.
- **whisper-server takes too long to bind** → the first poll tick may race with a not-yet-ready server; the POST is silently dropped and the next tick succeeds. UX: first transcript appears ~2–4s after PTT.
- **Focused app is on the blocklist** → the hotkey is a no-op for that utterance; the menubar dropdown surfaces the reason ("streaming disabled for this app").
- **Poll stalls** → state stays STREAMING; the user toggles off via the hotkey or the focus-loss policy stops it when they switch apps.
