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
--- The handler downstream is dikta-splice.lua. Because each transcript
--- is the model's reading of the *entire* session WAV up to that tick, the
--- splice's substring-replace mechanic naturally handles revisions: prior
--- transcript is the anchor in the field, new transcript replaces it.
---
--- Public API:
---   M.setEmissionHandler(fn)  Register the per-tick handler. Default no-op.
---   M.start(cfg)              Boot server + ffmpeg + timer. Idempotent.
---   M.stop(onDone)            Tear down timer + ffmpeg; if no emission landed
---                             during the session, run one final transcription
---                             against the now-flushed session WAV and dispatch
---                             it through the emission handler before invoking
---                             onDone. whisper-server stays alive across
---                             sessions; manual `stream-server.sh stop` to kill.
---   M.isStreaming()           Query state.

local M = {}

--- Mic picker — owns the avfoundation device selection. The user's choice is
--- persisted in hs.settings (NSUserDefaults) and is the source of truth for
--- which input ffmpeg should record from. Reading it at session start (not
--- module load) means the menu pick takes effect on the next PTT without a
--- Hammerspoon reload.
local mic = require("dikta-mic")

-- ───── constants ────────────────────────────────────────────────────────────

--- Repo-derived fallback paths to bin/stream.sh (record) and
--- bin/stream-server.sh (start/stop). install.sh writes the real,
--- install-location paths into dikta-config.lua and the streaming-mode caller
--- passes them via cfg.stream_sh / cfg.server_sh, which override these; the
--- defaults only cover configs predating those keys. NOTE the directory is
--- `dicta` — the repo checkout name — which is deliberately spelled
--- differently from the product name "Dikta". Deriving any runtime path from
--- the product spelling is the regression that broke recording; scratch paths
--- are derived from the *runtime* stream.sh below, never from this constant.
local DEFAULT_STREAM_SH = os.getenv("HOME") ..
  "/Projects/myStash/dicta/bin/stream.sh"
local DEFAULT_SERVER_SH = os.getenv("HOME") ..
  "/Projects/myStash/dicta/bin/stream-server.sh"

--- HTTP endpoint the daemon serves. Port matches stream-server.sh's default.
local SERVER_URL = "http://127.0.0.1:8472/inference"

--- Absolute path to system curl. Stable across every macOS install
--- (system-provided, not Homebrew). Named here per A2 — no inline literals
--- at hs.task call sites.
local CURL_BIN = "/usr/bin/curl"

--- Absolute path to system kill. Stable across every macOS install.
--- Named here per A2 — no inline literals at hs.task call sites.
local KILL_BIN = "/bin/kill"

--- Seconds between polls. 2s balances "feels live" vs whisper inference cost
--- on M-series with large-v3-turbo over a growing session WAV.
local POLL_INTERVAL_S = 2.0

--- Basenames of the two repo-local scratch WAVs: the continuous session
--- capture and the per-tick snapshot the poller hands the server. The
--- containing tmp/ directory is derived at session start from the *runtime*
--- stream.sh path (see deriveScratchPaths / M.start) so it always tracks the
--- real checkout location. Project rule: never /tmp (CLAUDE.md § Scratch paths).
local SESSION_WAV_NAME = "stream-session.wav"
local SNAPSHOT_WAV_NAME = "stream-snapshot.wav"

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

--- Callback fired when M.stop() has fully torn down + finalized — including
--- any post-stop transcription pass. Set by M.stop, invoked by the ffmpeg
--- exit callback. Nil between sessions.
local pendingOnDone = nil

--- Absolute path to the ffmpeg binary, set by M.start from cfg.ffmpeg_path
--- (install-time-resolved). Hammerspoon launches from launchd with a
--- minimal PATH and cannot look up `ffmpeg` itself, and the Homebrew
--- prefix differs between Apple Silicon and Intel — install.sh writes the
--- resolved absolute path into dikta-config.lua. Falls back to
--- the common Homebrew locations when cfg is silent (older configs).
local ffmpegPath = nil

--- Absolute paths to the session WAV (continuous capture) and the per-tick
--- snapshot the poller hands the server. Derived in M.start from the runtime
--- stream.sh path so they live in the real checkout's tmp/ dir rather than a
--- path baked in at module load. Nil until the first M.start.
local sessionWav = nil
local snapshotWav = nil

--- Derive the repo-local scratch WAV paths from the runtime stream.sh path by
--- stripping `/bin/<file>` to reach the repo root, then appending /tmp/<name>.
--- Driven by the *resolved* stream.sh (cfg.stream_sh when set), not a
--- module-load constant, so the scratch dir always tracks the real checkout
--- location — the divergence that broke recording when the repo dir (`dicta`)
--- and the product name (`Dikta`) were spelled differently.
--- @param streamSh string Absolute path to bin/stream.sh for this session.
local function deriveScratchPaths(streamSh)
  local tmpDir = streamSh:gsub("/bin/[^/]+$", "/tmp")
  sessionWav = tmpDir .. "/" .. SESSION_WAV_NAME
  snapshotWav = tmpDir .. "/" .. SNAPSHOT_WAV_NAME
end

--- Test whether a filesystem path is readable. Used to probe the common
--- ffmpeg locations when cfg.ffmpeg_path is missing.
--- @param path string Absolute filesystem path.
--- @return boolean True iff the path opens for reading.
local function pathExists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

--- Pick an ffmpeg location: explicit cfg value wins, otherwise scan the
--- two common Homebrew prefixes (Apple Silicon then Intel). Last-resort
--- returns the Apple Silicon path so hs.task surfaces a clear "no such
--- file" exit rather than the Lua module crashing on startup.
--- @param fromCfg string|nil Value from cfg.ffmpeg_path, may be nil.
--- @return string Absolute ffmpeg path to use for this session.
local function resolveFfmpegPath(fromCfg)
  if fromCfg and fromCfg ~= "" and pathExists(fromCfg) then return fromCfg end
  for _, p in ipairs({"/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"}) do
    if pathExists(p) then
      print(string.format(
        "[dk-stream] ffmpeg_path not in config; falling back to %s — re-run ./install.sh to lock it in",
        p))
      return p
    end
  end
  return "/opt/homebrew/bin/ffmpeg"
end

-- ───── poll cycle ───────────────────────────────────────────────────────────

--- POST the snapshot WAV to whisper-server and dispatch the parsed transcript.
--- Runs after the snapshot finalisation step completes successfully.
local function postSnapshot()
  local task = hs.task.new(CURL_BIN,
    function(exit, stdout, _stderr)
      pollInFlight = false
      if exit ~= 0 then
        print(string.format("[dk-stream] skip: curl exit=%d", exit))
        return
      end
      if stdout == nil or stdout == "" then
        print("[dk-stream] skip: empty stdout")
        return
      end
      local ok, parsed = pcall(hs.json.decode, stdout)
      if not ok or type(parsed) ~= "table" or type(parsed.text) ~= "string" then
        print("[dk-stream] skip: bad json")
        return
      end
      local text = parsed.text:gsub("^%s+", ""):gsub("%s+$", "")
      if text == "" then
        print("[dk-stream] skip: empty text")
        return
      end
      if text == lastDispatchedText then
        print("[dk-stream] skip: dup")
        return
      end
      lastDispatchedText = text
      print(string.format("[dk-stream] emit: %s", text))
      onEmission(text)
    end,
    {"-s", "-F", "file=@" .. snapshotWav, SERVER_URL})
  task:start()
end

--- Final-pass transcription fired by the ffmpeg exit callback after M.stop().
--- Runs unconditionally on stop: ffmpeg has now flushed the WAV trailer so
--- the snapshot+POST succeeds where the live-poll path may have failed with
--- AVERROR_INVALIDDATA (exit 183) early in the session, AND captures the
--- 1-2s tail of audio between the last live poll and the PTT release that
--- would otherwise be lost. The result is dispatched through onEmission
--- (still the splice handler until the caller's onDone runs), so even
--- utterances shorter than the live-poll's first-success threshold paste
--- a transcript, and longer ones get their tail captured. Dedup against
--- lastDispatchedText prevents a no-op splice flash when the final pass
--- exactly matches the last live emission.
--- @param onDone function|nil Invoked after the emission has been dispatched
---                            (success or failure), so the caller can finish
---                            tearing down state (e.g. splice.stopSession).
local function finalizeAndEmit(onDone)
  print("[dk-stream] finalize: begin")
  hs.task.new(ffmpegPath,
    function(exit, _stdout, _stderr)
      if exit ~= 0 then
        print(string.format("[dk-stream] finalize: snapshot exit=%d", exit))
        os.remove(snapshotWav)
        if onDone then onDone() end
        return
      end
      hs.task.new(CURL_BIN,
        function(curlExit, stdout, _curlStderr)
          if curlExit ~= 0 then
            print(string.format("[dk-stream] finalize: curl exit=%d", curlExit))
          elseif stdout == nil or stdout == "" then
            print("[dk-stream] finalize: empty stdout")
          else
            local ok, parsed = pcall(hs.json.decode, stdout)
            if not ok or type(parsed) ~= "table" or type(parsed.text) ~= "string" then
              print("[dk-stream] finalize: bad json")
            else
              local text = parsed.text:gsub("^%s+", ""):gsub("%s+$", "")
              if text == "" then
                print("[dk-stream] finalize: empty text")
              elseif text == lastDispatchedText then
                print("[dk-stream] finalize: dup")
              else
                lastDispatchedText = text
                print(string.format("[dk-stream] finalize emit: %s", text))
                onEmission(text)
              end
            end
          end
          os.remove(snapshotWav)
          if onDone then onDone() end
        end,
        {"-s", "-F", "file=@" .. snapshotWav, SERVER_URL}):start()
    end,
    {"-hide_banner", "-loglevel", "error", "-y",
     "-i", sessionWav, "-c", "copy", snapshotWav}):start()
end

--- Finalise the in-progress session WAV into a snapshot the server can parse,
--- then chain into the POST. Two hs.task spawns per tick (snapshot, POST) so
--- neither blocks the Hammerspoon main thread.
local function snapshotAndPost()
  if pollInFlight then
    print("[dk-stream] skip: poll in flight")
    return
  end
  pollInFlight = true
  local task = hs.task.new(ffmpegPath,
    function(exit, _stdout, _stderr)
      if exit ~= 0 then
        print(string.format("[dk-stream] skip: snapshot exit=%d", exit))
        pollInFlight = false
        return
      end
      postSnapshot()
    end,
    {"-hide_banner", "-loglevel", "error", "-y",
     "-i", sessionWav, "-c", "copy", snapshotWav})
  task:start()
end

-- ───── lifecycle ────────────────────────────────────────────────────────────

--- Register the per-tick emission handler. Default is a no-op so the module
--- ships callable on its own; dikta-stream-mode wires the splice.
function M.setEmissionHandler(fn)
  onEmission = fn or function(_line) end
end

--- Boot the pipeline: server first (model load takes ~1s — must precede the
--- first inference call), then ffmpeg, then the timer. Idempotent — second
--- M.start() while running exits early.
--- @param cfg table Optional config; .stream_sh and .server_sh override paths.
function M.start(cfg)
  if isStreaming then
    print("[dk-stream] start: skip (already streaming)")
    return false
  end
  print("[dk-stream] start: begin")
  local streamSh = (cfg and cfg.stream_sh) or DEFAULT_STREAM_SH
  local serverSh = (cfg and cfg.server_sh) or DEFAULT_SERVER_SH
  -- Pin the scratch WAV paths to the *runtime* stream.sh location for this
  -- session, so the recorder writes into the real checkout's tmp/ dir.
  deriveScratchPaths(streamSh)
  ffmpegPath = resolveFfmpegPath(cfg and cfg.ffmpeg_path)
  -- The mic picker is the source of truth for which input ffmpeg records
  -- from. Read at session start (not module load) so menu changes take
  -- effect on the next PTT without hs.reload(). Pass as the 2nd
  -- positional arg to stream.sh's `record` subcommand, which accepts
  -- `record <wav-path> [device]`.
  local audioDevice = mic.loadAudioDevice()
  print(string.format("[dk-stream] start: audio_device=%s", audioDevice))
  os.remove(sessionWav)
  lastDispatchedText = ""
  pollInFlight = false
  hs.task.new(serverSh, function(_exit, _stdout, _stderr) end, {"start"}):start()
  ffmpegTask = hs.task.new(streamSh,
    function(exit, _stdout, _stderr)
      print(string.format("[dk-stream] ffmpeg exit=%d", exit))
      -- ffmpeg only exits when M.stop() sent it SIGTERM (or it crashed). At
      -- this point the session WAV has its trailer flushed and is a valid
      -- input for inference. Always run one final transcription, even when
      -- live emissions fired during the session: there's always 1-2s of
      -- audio between the last live poll's snapshot and the user's PTT
      -- release that would otherwise be silently dropped. The dedup check
      -- inside finalizeAndEmit prevents a no-op flash when the final pass
      -- matches the last live emission. The pendingOnDone hook (set by
      -- M.stop) is invoked after the final emission dispatches so the
      -- caller can tear down the splice with the transcript already pasted.
      local cb = pendingOnDone
      pendingOnDone = nil
      finalizeAndEmit(cb)
    end,
    {"record", sessionWav, audioDevice})
  ffmpegTask:start()
  pollTimer = hs.timer.doEvery(POLL_INTERVAL_S, snapshotAndPost)
  isStreaming = true
  print("[dk-stream] start: end")
  return true
end

--- Tear down the pipeline: stop the timer, mark not-streaming so any
--- in-flight poll bails, then SIGTERM ffmpeg. The ffmpeg exit callback
--- (set in M.start) handles the post-stop transcription pass and fires
--- onDone when the session is fully wound down.
---
--- whisper-server is intentionally NOT stopped here. The model load is
--- ~14s of warmup that every session would otherwise eat on a cold start,
--- which makes short utterances impossible to transcribe in the live
--- poll path. Leaving the server alive across sessions trades ~2GB of
--- resident memory for instant-feeling subsequent sessions. To kill it
--- manually, run `bin/stream-server.sh stop`.
--- @param onDone function|nil Fires when ffmpeg has exited and the post-
---                            stop transcription (if any) has dispatched.
---                            If no ffmpeg task was active, fires inline.
function M.stop(onDone)
  print(string.format("[dk-stream] stop: begin isStreaming=%s", tostring(isStreaming)))
  if pollTimer then pollTimer:stop(); pollTimer = nil end
  isStreaming = false
  if ffmpegTask and ffmpegTask:isRunning() then
    -- Recorder is live: stash onDone, SIGTERM ffmpeg, and let its exit
    -- callback (set in M.start) run the post-stop transcription and then
    -- fire onDone. This is the normal PTT-release path.
    pendingOnDone = onDone
    local pid = ffmpegTask:pid()
    ffmpegTask = nil
    if pid and pid > 0 then
      hs.task.new(KILL_BIN, nil, {"-TERM", tostring(pid)}):start()
    end
  else
    -- No live recorder: either none started, or ffmpeg already exited (e.g.
    -- it died on launch). Its one-shot exit callback has already fired and
    -- will NOT fire again, so invoke onDone here directly. Without this the
    -- caller's teardown (splice stop, menubar → idle) is stranded and the
    -- finalize spinner spins forever — the exact symptom a missing scratch
    -- dir produced before the path fix.
    ffmpegTask = nil
    pendingOnDone = nil
    if onDone then onDone() end
  end
  print("[dk-stream] stop: end")
end

--- Query state.
--- @return boolean True iff a streaming session is currently active.
function M.isStreaming()
  return isStreaming
end

return M
