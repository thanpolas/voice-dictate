--- @fileoverview Streaming session orchestrator — composes the active streaming
--- engine with voice-dictate-splice (paste layer) into a single session API.
--- The engine is selected from settings on each startSession: the stable
--- ffmpeg + whisper-server engine (voice-dictate-stream) by default, or the
--- experimental whisper-stream engine (voice-dictate-stream-whisper) when the
--- menubar Engine choice selects it. Both satisfy the same engine contract
--- (setEmissionHandler / start / stop / isStreaming), so this module drives
--- either the same way. Owns no hotkeys; the main module's PTT and toggle
--- handlers call into M.startSession/M.stopSession directly.
---
--- Public API:
---   M.init()              Wire focus-loss self-stop. Call once from voice-dictate.lua's M.start().
---   M.startSession(cfg)   Select the engine, boot it + start the splice. Idempotent.
---   M.stopSession()       Tear down the splice + the engine. Safe to repeat.
---   M.isActive()          True iff a session is currently running.

local M = {}

--- The stable engine — ffmpeg AVFoundation capture + whisper-server daemon +
--- polling timer. The default; satisfies the engine contract.
local engineFfmpeg = require("voice-dictate-stream")

--- The experimental engine — whisper-stream + SDL2 capture. Opt-in; satisfies
--- the same engine contract. See its @fileoverview for the DSP caveat.
local engineWhisper = require("voice-dictate-stream-whisper")

--- Settings store — supplies the engine choice read at session start.
local settings = require("voice-dictate-settings")

--- Per-emission paste mechanic — owns the clipboard splice + focus stop.
local splice = require("voice-dictate-splice")

--- The engine driving the current (or most recent) session. Defaults to the
--- stable engine; reselected from settings on every startSession, so a menu
--- change applies on the next session without hs.reload().
local activeEngine = engineFfmpeg

-- ───── helpers ────────────────────────────────────────────────────────────────

--- Resolve the engine module for the current "engine" setting value.
--- @return table The whisper engine when selected, otherwise the ffmpeg engine.
local function selectEngine()
  if settings.get(settings.SETTING.ENGINE) == settings.ENGINE.WHISPER_STREAM then
    return engineWhisper
  end
  return engineFfmpeg
end

-- ───── public API ───────────────────────────────────────────────────────────

--- Wire the focus-loss self-stop once at module setup time. Splice fires the
--- onStop hook from its hs.window.filter focus-change handler; we route that to
--- the active engine's stop() so the pipeline tears down alongside the splice
--- when focus leaves the field.
function M.init()
  splice.setOnStop(function() activeEngine.stop() end)
end

--- Begin a streaming session. Selects the engine from settings, then starts the
--- splice first so the first emission lands in a session that already has the
--- clipboard snapshot + focus subscription ready. Splice mode is always
--- in-place replace (not append-only): every engine emits the full current
--- transcript each tick, so each emission revises the previous and the splice's
--- substring-replace preserves prefix + revises tail. The legacy
--- cfg.stream_append_only knob is no longer honoured.
--- @param cfg table Optional config routed to the engine (.stream_sh / .server_sh
---                  for ffmpeg; .stream_whisper_sh for whisper).
function M.startSession(cfg)
  if M.isActive() then return end
  activeEngine = selectEngine()
  splice.startSession({append_only = false})
  activeEngine.setEmissionHandler(splice.applyEmission)
  activeEngine.start(cfg)
end

--- End a streaming session. The splice must stay live through the engine's
--- stop() because an engine may dispatch one final emission during teardown
--- (the ffmpeg engine's post-stop pass captures the audio tail between the last
--- poll and release; the whisper engine has no final pass). Teardown order:
---   1. activeEngine.stop(onDone) — stop the engine, dispatch any final
---      emission, then invoke onDone.
---   2. onDone — drop the emission handler now that nothing will fire again,
---      tear down the splice, then invoke the caller's onDone so it can flip
---      the menubar state out of "finalizing".
--- @param onDone function|nil Fires after the session has fully wound down,
---                            including any final emission being pasted.
function M.stopSession(onDone)
  activeEngine.stop(function()
    activeEngine.setEmissionHandler(nil)
    splice.stopSession()
    if onDone then onDone() end
  end)
end

--- True iff either engine or the splice is currently active. Checks both
--- engines (not only the active one) so a lingering session from the other
--- engine still blocks a new start; the splice OR is defensive against a race
--- where one side has torn down but the other has not yet.
--- @return boolean
function M.isActive()
  return engineFfmpeg.isStreaming() or engineWhisper.isStreaming() or splice.isActive()
end

return M
