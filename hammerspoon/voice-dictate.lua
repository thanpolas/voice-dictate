--- @fileoverview Hotkey-driven local dictation: PTT + toggle, whisper.cpp backend.
---
--- Spawns bin/dictate.sh for the actual recording and transcription; this module
--- owns the macOS-side concerns: hotkeys, state machine, menubar, paste.
---
--- Public API:
---   M.start()  bind hotkeys, mount menubar item. Idempotent — calls stop() first.
---   M.stop()   tear down hotkeys + menubar + any in-flight task. Safe to repeat.

local M = {}

-- ───── constants ────────────────────────────────────────────────────────────

--- Absolute path to the shell entry point that records and transcribes audio.
local DICTATE_SH = os.getenv("HOME") .. "/Projects/myStash/voice-dictate/bin/dictate.sh"

--- Modifier set for the toggle hotkey (tap to start, tap to stop).
local TOGGLE_MODS = {"cmd", "shift"}

--- Key bound alongside TOGGLE_MODS to start/stop dictation.
local TOGGLE_KEY = "D"

--- macOS keycode for Right Option — the PTT trigger. Left Option (58) is ignored.
local RIGHT_ALT_KEYCODE = 61

--- Milliseconds to wait after stopping recording before reading the WAV — gives
--- ffmpeg time to flush the trailer cleanly on SIGTERM.
local FLUSH_DELAY_S = 0.2

-- ───── module state ─────────────────────────────────────────────────────────

--- True between startRecording() and stopRecording().
local recording = false

--- The hs.task running ffmpeg. Nil when idle. Terminated via task:terminate().
local recordTask = nil

--- Absolute path of the WAV being captured for the current utterance.
local currentWav = nil

--- The menubar item showing recording status. Nil before start() / after stop().
local menubar = nil

--- Binding handle for the toggle hotkey (returned by hs.hotkey.bind).
local hotkeyToggle = nil

--- Eventtap watching flagsChanged events to implement push-to-talk on Right Option.
local pttTap = nil

-- ───── helpers ──────────────────────────────────────────────────────────────

--- Compute a unique temporary WAV path under /tmp.
--- @return string Absolute /tmp path with a unix-timestamp suffix.
local function newWavPath()
  return string.format("/tmp/voice-dictate-%d.wav", os.time())
end

--- Update the menubar item title to reflect recording state.
--- @param isRecording boolean True to show "● REC", false to clear.
local function setMenubarRecording(isRecording)
  if not menubar then return end
  menubar:setTitle(isRecording and "● REC" or "")
end

--- Play the macOS Tink sound (start cue). No-op if the system sound is missing.
local function playStartCue()
  local s = hs.sound.getByName("Tink")
  if s then s:play() end
end

--- Play the macOS Pop sound (stop cue). No-op if the system sound is missing.
local function playStopCue()
  local s = hs.sound.getByName("Pop")
  if s then s:play() end
end

--- Show a Hammerspoon notification — used for transcription failures.
--- @param title string Short header text.
--- @param body string Body text shown beneath the title.
local function notify(title, body)
  hs.notify.new({title = title, informativeText = body}):send()
end

--- Synchronously transcribe currentWav and paste the result into the focused app.
--- Surfaces failures via notify() + Hammerspoon Console; never throws.
local function transcribeAndPaste()
  if not currentWav then return end
  local cmd = DICTATE_SH .. " transcribe '" .. currentWav .. "'"
  local out, status = hs.execute(cmd, true)
  if not status or out == nil or out:gsub("%s+", "") == "" then
    notify("voice-dictate", "transcription failed — see Hammerspoon Console")
    print("voice-dictate transcribe failed: " .. tostring(out))
    return
  end
  local transcript = out:gsub("[\n%s]+$", "")
  hs.pasteboard.setContents(transcript)
  hs.eventtap.keyStroke({"cmd"}, "v", 0)
end

-- ───── state transitions ────────────────────────────────────────────────────

--- Spawn dictate.sh record as a background task; transition to recording state.
--- No-op if already recording (PTT held while toggle active, or vice versa).
local function startRecording()
  if recording then return end
  currentWav = newWavPath()
  recordTask = hs.task.new(DICTATE_SH, nil, {"record", currentWav})
  recordTask:start()
  recording = true
  setMenubarRecording(true)
  playStartCue()
end

--- Terminate the recording task; after a short flush delay, transcribe and paste.
--- No-op if not currently recording.
local function stopRecording()
  if not recording then return end
  if recordTask then
    recordTask:terminate()
    recordTask = nil
  end
  recording = false
  setMenubarRecording(false)
  playStopCue()
  hs.timer.doAfter(FLUSH_DELAY_S, transcribeAndPaste)
end

-- ───── input handlers ───────────────────────────────────────────────────────

--- Toggle handler: flip recording state on each tap of TOGGLE_MODS + TOGGLE_KEY.
local function onToggleTap()
  if recording then stopRecording() else startRecording() end
end

--- PTT handler. Fires on every modifier change; filters to Right Option keycode
--- and uses the alt flag to distinguish press (start) from release (stop).
--- @param event hs.eventtap.event The flagsChanged event.
--- @return boolean Always false — never swallow the event.
local function onFlagsChanged(event)
  if event:getKeyCode() ~= RIGHT_ALT_KEYCODE then return false end
  local flags = event:getFlags()
  if flags.alt and not recording then
    startRecording()
  elseif not flags.alt and recording then
    stopRecording()
  end
  return false
end

-- ───── lifecycle ────────────────────────────────────────────────────────────

--- Bind global hotkeys and start the flagsChanged eventtap.
local function bindHotkeys()
  hotkeyToggle = hs.hotkey.bind(TOGGLE_MODS, TOGGLE_KEY, onToggleTap)
  pttTap = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, onFlagsChanged)
  pttTap:start()
end

--- Unbind global hotkeys and stop the flagsChanged eventtap.
local function unbindHotkeys()
  if hotkeyToggle then hotkeyToggle:delete(); hotkeyToggle = nil end
  if pttTap then pttTap:stop(); pttTap = nil end
end

--- Install hotkeys + menubar. Idempotent: tears down any prior state first.
function M.start()
  M.stop()
  menubar = hs.menubar.new()
  setMenubarRecording(false)
  bindHotkeys()
  print("voice-dictate: ready (PTT = Right Option, Toggle = Cmd+Shift+D)")
end

--- Tear down hotkeys + menubar + any in-flight recording. Safe to call repeatedly.
function M.stop()
  unbindHotkeys()
  if menubar then menubar:delete(); menubar = nil end
  if recordTask then recordTask:terminate(); recordTask = nil end
  recording = false
end

return M
