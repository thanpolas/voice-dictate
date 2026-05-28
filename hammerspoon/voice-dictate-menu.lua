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
---   M.setStreaming(b)  swap between the idle icon and the `● LIVE` title.

local M = {}

--- Mic picker — scan / persist / menu. Embedded as the Microphone submenu.
local mic = require("voice-dictate-mic")

-- ───── constants ──────────────────────────────────────────────────────────────

--- Menubar title shown while a streaming session is active. Idle uses an icon.
local TITLE_STREAMING = "● LIVE"

--- Text glyph fallback when the canvas idle icon cannot be rendered.
local TITLE_IDLE_FALLBACK = "○"

-- ───── module state ───────────────────────────────────────────────────────────

--- The single menubar item. Nil before mount() / after unmount().
local menubar = nil

--- Injected control table from the main module (see M.mount). Nil until mounted.
local ctl = nil

--- Pre-rendered idle icon (hs.image template), built once on mount. May be nil.
local idleIcon = nil

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

--- True while the main module reports an active streaming session.
--- @return boolean
local function isStreaming()
  return ctl ~= nil and ctl.isStreaming()
end

--- Swap between the idle icon and the streaming title.
--- @param streaming boolean True shows `● LIVE`; false restores the idle icon.
function M.setStreaming(streaming)
  if not menubar then return end
  if streaming then
    menubar:setIcon(nil)
    menubar:setTitle(TITLE_STREAMING)
  else
    showIdle()
  end
end

-- ───── dropdown ────────────────────────────────────────────────────────────────

--- Status line text for the dropdown header.
--- @return string "Streaming…" while a session is active, otherwise "Idle".
local function statusText()
  if isStreaming() then return "Streaming…" end
  return "Idle"
end

--- Build the dropdown contents. Registered as a callback so it re-reads state
--- and re-scans mics on every open. Surfaces the two Hammerspoon functions the
--- hidden HS icon would otherwise provide (console, reload) plus an icon-restore.
--- @return table Menu descriptors for hs.menubar:setMenu().
local function buildMenu()
  local toggleLabel = (isStreaming() and "Stop Dictation" or "Start Dictation")
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
  showIdle()
  if ctl.hideHsIcon then hs.menuIcon(false) end
end

--- Remove the menubar item. Safe to call repeatedly. Does NOT restore
--- Hammerspoon's icon — that would flicker on every hs.reload(); the
--- dropdown's "Show Hammerspoon Menu Icon" is the explicit restore path.
function M.unmount()
  if menubar then menubar:delete(); menubar = nil end
end

return M
