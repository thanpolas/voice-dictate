--- @fileoverview Menubar command center for voice-dictate (Dikta): the single
--- menubar item, its dropdown, the idle icon (rendered in code via hs.canvas),
--- and the streaming title.
---
--- Hides Hammerspoon's own menu icon so this is the one control surface, and
--- surfaces the Hammerspoon Console + reload in the dropdown since hiding the
--- icon removes their usual access. The main module owns session state and
--- behavior; this module owns everything shown in the menu bar and is driven
--- through an injected control table (no circular require back into the main).
---
--- Public API:
---   M.mount(ctl)       create the menubar item, wire the dropdown + idle icon,
---                      hide Hammerspoon's icon (per ctl.hideHsIcon). Idempotent.
---   M.unmount()        remove the menubar item. Safe to repeat.
---   M.setState(s)      swap the title/icon for one of the three states:
---                      "idle" | "streaming" | "finalizing". "finalizing" is
---                      the post-stop window where ffmpeg has flushed the
---                      WAV trailer and the final whisper-server pass is in
---                      flight — the visual signal that work continues after
---                      PTT release until the final transcript pastes.

local M = {}

--- Mic picker — scan / persist / menu. Embedded as the Microphone submenu.
local mic = require("voice-dictate-mic")

-- ───── constants ──────────────────────────────────────────────────────────────

--- The three menubar states. "idle" shows the Dikta mark icon; "streaming"
--- and "finalizing" show distinct text titles so the user can tell which
--- phase the session is in. State strings are exposed via setState().
local STATE_IDLE = "idle"
local STATE_STREAMING = "streaming"
local STATE_FINALIZING = "finalizing"

--- Menubar title shown while a streaming session is active. Idle uses an icon.
local TITLE_STREAMING = "● LIVE"

--- Animation frames shown during the post-stop finalize window. The dot
--- count cycles to telegraph "work in flight" without making the menubar
--- width jitter excessively — each frame ends at the same Unicode pad so
--- the title slot stays roughly the same width across frames.
local FINALIZING_FRAMES = {"● .  ", "● .. ", "● ..."}

--- Seconds between spinner frames. 0.35s is brisk enough to feel like
--- progress without flashing.
local FINALIZING_FRAME_INTERVAL_S = 0.35

--- Text glyph fallback when the canvas idle icon cannot be rendered.
local TITLE_IDLE_FALLBACK = "○"

-- ───── module state ───────────────────────────────────────────────────────────

--- The single menubar item. Nil before mount() / after unmount().
local menubar = nil

--- Injected control table from the main module (see M.mount). Nil until mounted.
local ctl = nil

--- Pre-rendered idle icon (hs.image template), built once on mount. May be nil.
local idleIcon = nil

--- Current display state — drives both the menubar title/icon and the
--- dropdown's status line + toggle label. Updated only via setState().
local state = STATE_IDLE

--- hs.timer cycling FINALIZING_FRAMES while state == "finalizing". Nil
--- in every other state; stopped + cleared by stopFinalizingSpinner().
local spinnerTimer = nil

--- Current index into FINALIZING_FRAMES; advances on each timer tick.
local spinnerFrame = 1

-- ───── idle icon ──────────────────────────────────────────────────────────────

--- Render the Dikta spoken-mark — a voice-dot resolving into two text-strokes —
--- as a template image for the menubar. macOS draws the status-item image at
--- its native point size (it does NOT scale to the bar height), so the canvas
--- is sized to ~bar height — the brand geometry scaled ×3 — for the mark to
--- fill the bar instead of rendering tiny. Opaque black fills; setIcon's
--- template flag makes macOS auto-invert for light/dark. Proportions match
--- brand/dikta-mark.svg (scaled ×2.5 to sit just under the bar height, in line
--- with neighbouring icons). Returns nil if hs.canvas is unavailable.
--- @return hs.image|nil The template icon, or nil on failure.
local function buildIdleIcon()
  if not hs.canvas then return nil end
  local c = hs.canvas.new({x = 0, y = 0, w = 35, h = 15})
  c[1] = {type = "circle", center = {x = 7.5, y = 7.5}, radius = 6.25,
          action = "fill", fillColor = {white = 0, alpha = 1}}
  c[2] = {type = "rectangle", frame = {x = 18.75, y = 1.75, w = 15, h = 4},
          action = "fill", fillColor = {white = 0, alpha = 1}}
  c[3] = {type = "rectangle", frame = {x = 18.75, y = 9.25, w = 10, h = 4},
          action = "fill", fillColor = {white = 0, alpha = 1}}
  local img = c:imageFromCanvas()
  c:delete()
  return img
end

-- ───── presentation ───────────────────────────────────────────────────────────

--- Show the idle representation: the template icon, or the text glyph fallback.
--- Clears any streaming title.
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

--- Start cycling the finalizing-spinner frames on the menubar title.
--- Replaces any running spinner so re-entering finalizing from another
--- state doesn't leave a stale timer.
local function startFinalizingSpinner()
  if not menubar then return end
  if spinnerTimer then spinnerTimer:stop() end
  spinnerFrame = 1
  menubar:setIcon(nil)
  menubar:setTitle(FINALIZING_FRAMES[spinnerFrame])
  spinnerTimer = hs.timer.doEvery(FINALIZING_FRAME_INTERVAL_S, function()
    if not menubar then return end
    spinnerFrame = (spinnerFrame % #FINALIZING_FRAMES) + 1
    menubar:setTitle(FINALIZING_FRAMES[spinnerFrame])
  end)
end

--- Stop the finalizing spinner if it's running. Safe to call any time.
local function stopFinalizingSpinner()
  if spinnerTimer then
    spinnerTimer:stop()
    spinnerTimer = nil
  end
end

--- Transition the menubar between idle / streaming / finalizing. Unknown
--- state strings collapse to idle so the menubar can never get stuck on a
--- stale title. State is also read by the dropdown so the status line and
--- toggle label stay in sync with what the user sees on the bar.
--- @param s string One of "idle", "streaming", "finalizing".
function M.setState(s)
  state = (s == STATE_STREAMING or s == STATE_FINALIZING) and s or STATE_IDLE
  stopFinalizingSpinner()
  if not menubar then return end
  if state == STATE_STREAMING then
    menubar:setIcon(nil)
    menubar:setTitle(TITLE_STREAMING)
  elseif state == STATE_FINALIZING then
    startFinalizingSpinner()
  else
    showIdle()
  end
end

-- ───── dropdown ────────────────────────────────────────────────────────────────

--- Status line text for the dropdown header.
--- @return string "Streaming…" / "Finalizing…" while busy, otherwise "Idle".
local function statusText()
  if state == STATE_STREAMING then return "Streaming…" end
  if state == STATE_FINALIZING then return "Finalizing…" end
  return "Idle"
end

--- Build the dropdown contents. Registered as a callback so it re-reads state
--- and re-scans mics on every open. Surfaces the two Hammerspoon functions the
--- hidden HS icon would otherwise provide (console, reload) plus an icon-restore.
--- @return table Menu descriptors for hs.menubar:setMenu().
local function buildMenu()
  local toggleLabel = (state ~= STATE_IDLE and "Stop Dictation" or "Start Dictation")
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
---   onToggle(), isStreaming()->bool, onOpenConsole(), onReload(),
---   onShowHsIcon(), hotkeyHint (string), hideHsIcon (bool).
function M.mount(control)
  M.unmount()
  ctl = control
  idleIcon = buildIdleIcon()
  menubar = hs.menubar.new()
  menubar:setMenu(buildMenu)
  state = STATE_IDLE
  showIdle()
  if ctl.hideHsIcon then hs.menuIcon(false) end
end

--- Remove the menubar item. Safe to call repeatedly. Does NOT restore
--- Hammerspoon's icon — that would flicker on every hs.reload(); the
--- dropdown's "Show Hammerspoon Menu Icon" is the explicit restore path.
function M.unmount()
  stopFinalizingSpinner()
  if menubar then menubar:delete(); menubar = nil end
end

return M
