--- @fileoverview Streaming pipeline orchestrator — ffmpeg + whisper-server + timer.
---
--- Replaces the old whisper-stream/SDL2 stdout consumer. The new shape:
---   1. bin/stream.sh records the focused mic to a session WAV via AVFoundation
---      (so the Apple Voice Processing IO unit runs — see the ffmpeg rebuild plan).
---   2. bin/stream-server.sh keeps whisper.cpp loaded as an HTTP daemon on
---      loopback, so per-tick inference pays no model-load tax.
---   3. An hs.timer fires every POLL_INTERVAL_S, finalises an ffmpeg snapshot
---      of the in-progress WAV (whisper-server cannot parse the live file
---      until ffmpeg writes the WAV trailer), POSTs the snapshot to /inference,
---      parses the JSON, and dispatches the full transcript as a single
---      emission to the caller-registered handler.
---
--- The handler downstream is voice-dictate-splice.lua. Because each transcript
--- is the model's reading of the *entire* session WAV up to that tick, the
--- splice's substring-replace mechanic naturally handles revisions: prior
--- transcript is the anchor in the field, new transcript replaces it.
---
--- Public API:
---   M.setEmissionHandler(fn)  Register the per-tick handler. Default no-op.
---   M.start(cfg)              Boot server + ffmpeg + timer. Idempotent.
---   M.stop()                  Tear down timer, ffmpeg, server. Safe to repeat.
---   M.isStreaming()           Query state.

local M = {}

-- ───── constants ────────────────────────────────────────────────────────────

--- Repo-derived path to bin/stream.sh (record) and bin/stream-server.sh
--- (start/stop). The streaming-mode caller's cfg overrides these if set.
local DEFAULT_STREAM_SH = os.getenv("HOME") ..
  "/Projects/myStash/voice-dictate/bin/stream.sh"
local DEFAULT_SERVER_SH = os.getenv("HOME") ..
  "/Projects/myStash/voice-dictate/bin/stream-server.sh"

--- HTTP endpoint the daemon serves. Port matches stream-server.sh's default.
local SERVER_URL = "http://127.0.0.1:8472/inference"

--- Seconds between polls. 2s balances "feels live" vs whisper inference cost
--- on M-series with large-v3-turbo over a growing session WAV.
local POLL_INTERVAL_S = 2.0

--- Repo-local scratch directory for the session WAV and the snapshot the
--- poller hands to the server. Project rule: never /tmp (see CLAUDE.md
--- § Scratch paths). Derived from DEFAULT_STREAM_SH by stripping /bin/<file>.
local TMP_DIR = (DEFAULT_STREAM_SH:gsub("/bin/[^/]+$", "/tmp"))
local SESSION_WAV = TMP_DIR .. "/stream-session.wav"
local SNAPSHOT_WAV = TMP_DIR .. "/stream-snapshot.wav"

-- ───── module state ─────────────────────────────────────────────────────────

--- True between M.start() and M.stop(); read by streamMode.isActive().
local isStreaming = false

--- hs.task running bin/stream.sh record. Nil when idle.
local ffmpegTask = nil

--- hs.timer firing every POLL_INTERVAL_S. Nil when idle.
local pollTimer = nil

--- Last transcript text dispatched downstream — used as a dedup guard so
--- identical successive polls don't re-fire the splice for no change.
local lastDispatchedText = ""

--- True while a poll cycle is in flight, so the next tick doesn't queue a
--- second concurrent inference while inference for the prior is pending.
local pollInFlight = false

--- Caller-registered handler invoked once per cleaned transcript.
local onEmission = function(_line) end

-- ───── poll cycle ───────────────────────────────────────────────────────────

--- POST the snapshot WAV to whisper-server and dispatch the parsed transcript.
--- Runs after the snapshot finalisation step completes successfully.
local function postSnapshot()
  local task = hs.task.new("/usr/bin/curl",
    function(exit, stdout, _stderr)
      pollInFlight = false
      if exit ~= 0 or stdout == nil or stdout == "" then return end
      local ok, parsed = pcall(hs.json.decode, stdout)
      if not ok or type(parsed) ~= "table" or type(parsed.text) ~= "string" then
        return
      end
      local text = parsed.text:gsub("^%s+", ""):gsub("%s+$", "")
      if text == "" or text == lastDispatchedText then return end
      lastDispatchedText = text
      onEmission(text)
    end,
    {"-s", "-F", "file=@" .. SNAPSHOT_WAV, SERVER_URL})
  task:start()
end

--- Finalise the in-progress session WAV into a snapshot the server can parse,
--- then chain into the POST. Two hs.task spawns per tick (snapshot, POST) so
--- neither blocks the Hammerspoon main thread.
local function snapshotAndPost()
  if pollInFlight then return end
  pollInFlight = true
  local task = hs.task.new("/opt/homebrew/bin/ffmpeg",
    function(exit, _stdout, _stderr)
      if exit ~= 0 then
        pollInFlight = false
        return
      end
      postSnapshot()
    end,
    {"-hide_banner", "-loglevel", "error", "-y",
     "-i", SESSION_WAV, "-c", "copy", SNAPSHOT_WAV})
  task:start()
end

-- ───── lifecycle ────────────────────────────────────────────────────────────

--- Register the per-tick emission handler. Default is a no-op so the module
--- ships callable on its own; voice-dictate-stream-mode wires the splice.
function M.setEmissionHandler(fn)
  onEmission = fn or function(_line) end
end

--- Boot the pipeline: server first (model load takes ~1s — must precede the
--- first inference call), then ffmpeg, then the timer. Idempotent — second
--- M.start() while running exits early.
--- @param cfg table Optional config; .stream_sh and .server_sh override paths.
function M.start(cfg)
  if isStreaming then return false end
  local streamSh = (cfg and cfg.stream_sh) or DEFAULT_STREAM_SH
  local serverSh = (cfg and cfg.server_sh) or DEFAULT_SERVER_SH
  os.remove(SESSION_WAV)
  lastDispatchedText = ""
  pollInFlight = false
  hs.task.new(serverSh, function(_exit, _stdout, _stderr) end, {"start"}):start()
  ffmpegTask = hs.task.new(streamSh,
    function(_exit, _stdout, _stderr) end,
    {"record", SESSION_WAV})
  ffmpegTask:start()
  pollTimer = hs.timer.doEvery(POLL_INTERVAL_S, snapshotAndPost)
  isStreaming = true
  return true
end

--- Tear down the pipeline in reverse order: timer first, ffmpeg next, server
--- last. The server stays up across sessions in principle, but tearing it
--- down on M.stop keeps the lifecycle simple — start always pays the
--- ~1s warm-up. Re-evaluate if that latency becomes a friction point.
function M.stop()
  if pollTimer then pollTimer:stop(); pollTimer = nil end
  if ffmpegTask then
    local pid = ffmpegTask:pid()
    if pid and pid > 0 then
      hs.task.new("/bin/kill", nil, {"-TERM", tostring(pid)}):start()
    end
    ffmpegTask = nil
  end
  hs.task.new(DEFAULT_SERVER_SH, nil, {"stop"}):start()
  os.remove(SNAPSHOT_WAV)
  isStreaming = false
end

--- Query state.
--- @return boolean True iff a streaming session is currently active.
function M.isStreaming()
  return isStreaming
end

return M
