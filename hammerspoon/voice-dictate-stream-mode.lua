--- @fileoverview Streaming-mode orchestrator — binds the streaming hotkey,
--- composes voice-dictate-stream + voice-dictate-splice, and owns the focus-
--- loss wiring so the two halves stop together.
---
--- Sibling of the main voice-dictate.lua. The main module calls M.start(cfg)
--- from its own M.start() and M.stop() from its own M.stop(); the single-shot
--- path is untouched by this module.
---
--- Public API:
---   M.start(cfg)  Bind the streaming hotkey from cfg. Idempotent.
---   M.stop()      Unbind the hotkey; stop any in-flight session. Safe to repeat.

local M = {}

--- stdout consumer that turns whisper-stream lines into emissions.
local stream = require("voice-dictate-stream")

--- Per-emission paste mechanic — owns the clipboard splice + focus stop.
local splice = require("voice-dictate-splice")

-- ───── module state ─────────────────────────────────────────────────────────

--- hs.hotkey binding for the streaming toggle; nil while unbound.
local hotkey = nil

--- Cached config so the focus-loss callback can restart cleanly if needed.
local currentCfg = nil

-- ───── orchestration ────────────────────────────────────────────────────────

--- Begin a streaming session: start the splice (which subscribes focus),
--- wire the emission handler, then spawn whisper-stream. Splice goes first
--- so the first emission has somewhere to land.
local function startSession()
  if stream.isStreaming() then return end
  splice.startSession({append_only = currentCfg.stream_append_only})
  stream.setEmissionHandler(splice.applyEmission)
  stream.start(currentCfg)
end

--- End a streaming session: kill whisper-stream, drop the emission handler,
--- then tear down the splice (which restores the clipboard).
local function stopSession()
  stream.setEmissionHandler(nil)
  stream.stop()
  splice.stopSession()
end

--- Hotkey handler — flip session state on each tap of the streaming chord.
local function onStreamToggle()
  if stream.isStreaming() or splice.isActive() then
    stopSession()
  else
    startSession()
  end
end

-- ───── lifecycle ────────────────────────────────────────────────────────────

--- Bind the streaming hotkey + register the focus-loss self-stop hook.
--- Idempotent: prior bindings are torn down by M.stop() before re-binding.
--- @param cfg table Config table from voice-dictate-config.lua.
function M.start(cfg)
  M.stop()
  currentCfg = cfg
  splice.setOnStop(function() stream.stop() end)
  local mods = cfg.stream_toggle_mods or {"cmd", "shift"}
  local key = cfg.stream_toggle_key or "S"
  hotkey = hs.hotkey.bind(mods, key, onStreamToggle)
end

--- Unbind the streaming hotkey and stop any in-flight session.
--- Safe to call repeatedly; used by hs.reload() round-trips.
function M.stop()
  if hotkey then hotkey:delete(); hotkey = nil end
  stopSession()
  currentCfg = nil
end

return M
