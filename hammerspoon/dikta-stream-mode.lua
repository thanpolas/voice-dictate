--- @fileoverview Streaming session orchestrator — composes dikta-stream
--- (stdout consumer) with dikta-splice (paste layer) into a single
--- session API. Owns no hotkeys of its own; the main module's existing PTT and
--- toggle handlers call into M.startSession/M.stopSession directly.
---
--- Public API:
---   M.init()              Wire focus-loss self-stop. Call once from dikta.lua's M.start().
---   M.startSession(cfg)   Boot the pipeline + start the splice. Idempotent.
---   M.stopSession()       Tear down the splice + the pipeline. Safe to repeat.
---   M.isActive()          True iff a session is currently running.

local M = {}

--- Streaming pipeline orchestrator — owns the ffmpeg recorder, the
--- whisper-server daemon, and the polling timer that dispatches each
--- inference response as an emission.
local stream = require("dikta-stream")

--- Per-emission paste mechanic — owns the clipboard splice + focus stop.
local splice = require("dikta-splice")

-- ───── public API ───────────────────────────────────────────────────────────

--- Wire the focus-loss self-stop once at module setup time. Splice fires the
--- onStop hook from its hs.window.filter focus-change handler; we route that
--- to stream.stop() so the pipeline tears down alongside the splice when
--- focus leaves the field.
function M.init()
  splice.setOnStop(function() stream.stop() end)
end

--- Begin a streaming session. Splice goes first so the first emission lands
--- in a session that has clipboard snapshot + focus subscription ready.
--- Splice mode is always in-place replace (not append-only): the new
--- pipeline emits the full current transcript on each tick, so each new
--- emission is a revision of the previous one and the splice's
--- substring-replace mechanic preserves prefix + revises tail correctly.
--- The legacy cfg.stream_append_only knob is no longer honoured — left in
--- old config files it's ignored.
--- @param cfg table Optional config; .stream_sh and .server_sh route to stream.
function M.startSession(cfg)
  if stream.isStreaming() then return end
  splice.startSession({append_only = false})
  stream.setEmissionHandler(splice.applyEmission)
  stream.start(cfg)
end

--- End a streaming session. The splice must stay live through stream.stop()
--- because stream dispatches one final emission (the post-stop pass that
--- captures the tail of audio between the last live poll and PTT release).
--- Teardown order:
---   1. stream.stop(onDone) — SIGTERM ffmpeg, run the post-stop transcription,
---      then invoke onDone.
---   2. onDone — drop the emission handler now that nothing will fire again,
---      tear down the splice, then invoke the caller's onDone so it can flip
---      menubar state out of "finalizing".
--- @param onDone function|nil Fires after the session has fully wound down,
---                            including the final emission being pasted.
function M.stopSession(onDone)
  stream.stop(function()
    stream.setEmissionHandler(nil)
    splice.stopSession()
    if onDone then onDone() end
  end)
end

--- True iff either the pipeline or the splice is currently active. Both
--- should be live together; the OR is defensive against a race where one
--- side has torn down but the other has not yet.
--- @return boolean
function M.isActive()
  return stream.isStreaming() or splice.isActive()
end

return M
