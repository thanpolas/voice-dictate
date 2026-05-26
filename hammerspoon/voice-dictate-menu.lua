--- @fileoverview Menubar command center for voice-dictate (Dikta): the single
--- menubar item, its dropdown, the idle icon (rendered in code via hs.canvas),
--- the recording title, and the transcription spinner.
---
--- Hides Hammerspoon's own menu icon so this is the one control surface, and
--- surfaces the Hammerspoon Console + reload in the dropdown since hiding the
--- icon removes their usual access. The main module owns recording state and
--- behavior; this module owns everything shown in the menu bar and is driven
--- through an injected control table (no circular require back into the main).
---
--- Public API:
---   M.mount(ctl)       create the menubar item, wire the dropdown + idle icon,
---                      hide Hammerspoon's icon (per ctl.hideHsIcon). Idempotent.
---   M.unmount()        remove the menubar item + stop the spinner. Safe to repeat.
---   M.setRecording(b)  swap between the idle icon and the `● REC` title.
---   M.startSpinner()   animate the braille spinner during transcription.
---   M.stopSpinner()    stop it and restore the idle icon.

local M = {}

--- Mic picker — scan / persist / menu. Embedded as the Microphone submenu.
local mic = require("voice-dictate-mic")

-- ───── constants ──────────────────────────────────────────────────────────────

--- Menubar title shown while recording. Idle uses an icon (see buildIdleIcon).
local TITLE_RECORDING = "● REC"

--- Text glyph fallback when the canvas idle icon cannot be rendered.
local TITLE_IDLE_FALLBACK = "○"

--- Braille spinner frames shown while transcription is in flight.
local SPINNER_FRAMES = {"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

--- Seconds between spinner frame updates. 80ms is the standard CLI spinner rate.
local SPINNER_INTERVAL_S = 0.08

-- ───── module state ───────────────────────────────────────────────────────────

--- The single menubar item. Nil before mount() / after unmount().
local menubar = nil

--- Injected control table from the main module (see M.mount). Nil until mounted.
local ctl = nil

--- Pre-rendered idle icon (hs.image template), built once on mount. May be nil.
local idleIcon = nil

--- hs.timer animating the spinner while transcription runs. Nil otherwise.
local spinnerTimer = nil

-- ───── idle icon ──────────────────────────────────────────────────────────────

--- Render the Dikta spoken-mark — a voice-dot resolving into two text-strokes —
--- as a template image for the menubar. Opaque black fills; setIcon's template
--- flag makes macOS auto-invert for light/dark menubars. Geometry mirrors
--- brand/dikta-mark.svg. Returns nil if hs.canvas is unavailable.
--- @return hs.image|nil The 18×18 template icon, or nil on failure.
local function buildIdleIcon()
  if not hs.canvas then return nil end
  local c = hs.canvas.new({x = 0, y = 0, w = 18, h = 18})
  c[1] = {type = "circle", center = {x = 5, y = 9}, radius = 2.5,
          action = "fill", fillColor = {white = 0, alpha = 1}}
  c[2] = {type = "rectangle", frame = {x = 9.5, y = 6.7, w = 6, h = 1.6},
          action = "fill", fillColor = {white = 0, alpha = 1}}
  c[3] = {type = "rectangle", frame = {x = 9.5, y = 9.7, w = 4, h = 1.6},
          action = "fill", fillColor = {white = 0, alpha = 1}}
  local img = c:imageFromCanvas()
  c:delete()
  return img
end

-- ───── presentation ───────────────────────────────────────────────────────────

--- Show the idle representation: the template icon, or the text glyph fallback.
--- Clears any recording/spinner title.
local function showIdle()
  if not menubar then return end
  if idleIcon then
    menubar:setTitle("")
    menubar:setIcon(idleIcon, true)
  else
    menubar:setIcon(nil)
    menubar:setTitle(TITLE_IDLE_FALLBACK)
  end
end

--- True while the main module reports an active recording.
--- @return boolean
local function isRecording()
  return ctl ~= nil and ctl.isRecording()
end

--- Swap between the idle icon and the recording title.
--- @param recording boolean True shows `● REC`; false restores the idle icon.
function M.setRecording(recording)
  if not menubar then return end
  if recording then
    menubar:setIcon(nil)
    menubar:setTitle(TITLE_RECORDING)
  else
    showIdle()
  end
end

--- Animate the braille spinner while transcription runs. Skips the frame update
--- if recording has (re)started so `● REC` stays visible.
function M.startSpinner()
  if not menubar or spinnerTimer then return end
  local i = 1
  menubar:setIcon(nil)
  spinnerTimer = hs.timer.doEvery(SPINNER_INTERVAL_S, function()
    if menubar and not isRecording() then
      menubar:setTitle(SPINNER_FRAMES[i])
    end
    i = (i % #SPINNER_FRAMES) + 1
  end)
end

--- Stop the spinner and restore the idle icon (unless recording is active).
function M.stopSpinner()
  if spinnerTimer then
    spinnerTimer:stop()
    spinnerTimer = nil
  end
  if menubar and not isRecording() then
    showIdle()
  end
end

-- ───── dropdown ────────────────────────────────────────────────────────────────

--- Status line text for the dropdown header.
--- @return string "Recording…", "Transcribing…", or "Idle".
local function statusText()
  if isRecording() then return "Recording…" end
  if spinnerTimer then return "Transcribing…" end
  return "Idle"
end

--- Build the dropdown contents. Registered as a callback so it re-reads state
--- and re-scans mics on every open. Surfaces the two Hammerspoon functions the
--- hidden HS icon would otherwise provide (console, reload) plus an icon-restore.
--- @return table Menu descriptors for hs.menubar:setMenu().
local function buildMenu()
  local toggleLabel = (isRecording() and "Stop Dictation" or "Start Dictation")
  if ctl.hotkeyHint and ctl.hotkeyHint ~= "" then
    toggleLabel = toggleLabel .. "   " .. ctl.hotkeyHint
  end
  return {
    {title = "Dikta — " .. statusText(), disabled = true},
    {title = "-"},
    {title = toggleLabel, fn = function() ctl.onToggle() end},
    {title = "-"},
    {title = "Microphone", menu = mic.buildMicMenu()},
    {title = "-"},
    {title = "Open Console", fn = function() ctl.onOpenConsole() end},
    {title = "Reload Config", fn = function() ctl.onReload() end},
    {title = "-"},
    {title = "Show Hammerspoon Menu Icon", fn = function() ctl.onShowHsIcon() end},
  }
end

-- ───── lifecycle ───────────────────────────────────────────────────────────────

--- Create the menubar item, wire the dropdown + idle icon, and hide Hammerspoon's
--- own menu icon when requested. Idempotent — unmounts any prior item first.
--- @param control table Injected from the main module:
---   onToggle(), isRecording()->bool, onOpenConsole(), onReload(),
---   onShowHsIcon(), hotkeyHint (string), hideHsIcon (bool).
function M.mount(control)
  M.unmount()
  ctl = control
  idleIcon = buildIdleIcon()
  menubar = hs.menubar.new()
  menubar:setMenu(buildMenu)
  showIdle()
  if ctl.hideHsIcon then hs.menuIcon(false) end
end

--- Remove the menubar item and stop the spinner. Safe to call repeatedly. Does
--- NOT restore Hammerspoon's icon — that would flicker on every hs.reload(); the
--- dropdown's "Show Hammerspoon Menu Icon" is the explicit restore path.
function M.unmount()
  if spinnerTimer then spinnerTimer:stop(); spinnerTimer = nil end
  if menubar then menubar:delete(); menubar = nil end
end

return M
