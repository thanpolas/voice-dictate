--- @fileoverview Streaming pipeline lifecycle — recorder + server + poll timer.
---
--- The orchestrator for streaming dictation. The per-tick transcription
--- mechanics live in dikta-stream-infer.lua; ffmpeg-binary location lives in
--- dikta-ffmpeg.lua; this module owns the session lifecycle that drives them:
---   1. bin/stream.sh records the focused mic to a session WAV via AVFoundation
---      (so the Apple Voice Processing IO unit runs — see the ffmpeg rebuild plan).
---   2. bin/stream-server.sh keeps whisper.cpp loaded as an HTTP daemon on
---      loopback, so per-tick inference pays no model-load tax.
---   3. An hs.timer fires every POLL_INTERVAL_S and calls infer.pollOnce(),
---      which snapshots + POSTs + dispatches. On stop, the recorder's exit
---      callback runs infer.finalize() for the post-stop pass.
---
--- The emission handler downstream is dikta-splice.lua, wired by
--- dikta-stream-mode.lua via setEmissionHandler (delegated to infer).
---
--- Public API (unchanged across the module split — see the split plan):
---   M.setEmissionHandler(fn)  Register the per-tick handler. Default no-op.
---   M.start(cfg)              Boot server + ffmpeg + timer. Idempotent.
---   M.stop(onDone)            Tear down timer + ffmpeg; run one final
---                             transcription against the flushed session WAV
---                             and dispatch it before invoking onDone.
---                             whisper-server stays alive across sessions;
---                             manual `stream-server.sh stop` to kill.
---   M.isStreaming()           Query state.

local M = {}

--- Mic picker — owns the avfoundation device selection. The user's choice is
--- persisted in hs.settings (NSUserDefaults) and is the source of truth for
--- which input ffmpeg should record from. Reading it at session start (not
--- module load) means the menu pick takes effect on the next PTT without a
--- Hammerspoon reload.
local mic = require("dikta-mic")

--- ffmpeg-binary locator — shared with the mic picker.
local ffmpeg = require("dikta-ffmpeg")

--- Per-tick transcription mechanics — snapshot → POST → dispatch + finalize.
local infer = require("dikta-stream-infer")

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

--- Absolute path to system kill. Stable across every macOS install.
--- Named here per A2 — no inline literals at hs.task call sites.
local KILL_BIN = "/bin/kill"

--- Seconds between polls. 2s balances "feels live" vs whisper inference cost
--- on M-series with large-v3-turbo over a growing session WAV.
local POLL_INTERVAL_S = 2.0

--- Basenames of the two repo-local scratch WAVs: the continuous session
--- capture and the per-tick snapshot the poller hands the server. The
--- containing tmp/ directory is derived at session start from the *runtime*
--- stream.sh path (see deriveScratchPaths) so it always tracks the real
--- checkout location. Project rule: never /tmp (CLAUDE.md § Scratch paths).
local SESSION_WAV_NAME = "stream-session.wav"
local SNAPSHOT_WAV_NAME = "stream-snapshot.wav"

-- ───── module state ─────────────────────────────────────────────────────────

--- True between M.start() and M.stop(); read by streamMode.isActive().
local isStreaming = false

--- hs.task running bin/stream.sh record. Nil when idle.
local ffmpegTask = nil

--- hs.timer firing every POLL_INTERVAL_S. Nil when idle.
local pollTimer = nil

--- Absolute path to this session's session WAV — the recorder's output and
--- infer's read source. Set in M.start. Nil between sessions.
local sessionWav = nil

--- Callback fired when M.stop() has fully torn down + finalized — including
--- any post-stop transcription pass. Set by M.stop, invoked by the recorder's
--- exit callback. Nil between sessions.
local pendingOnDone = nil

-- ───── helpers ──────────────────────────────────────────────────────────────

--- Derive the repo-local scratch WAV paths from the runtime stream.sh path by
--- stripping `/bin/<file>` to reach the repo root, then appending /tmp/<name>.
--- Driven by the *resolved* stream.sh (cfg.stream_sh when set), not a
--- module-load constant, so the scratch dir always tracks the real checkout
--- location — the divergence that broke recording when the repo dir (`dicta`)
--- and the product name (`Dikta`) were spelled differently.
--- @param streamSh string Absolute path to bin/stream.sh for this session.
--- @return string session WAV path
--- @return string snapshot WAV path
local function deriveScratchPaths(streamSh)
  local tmpDir = streamSh:gsub("/bin/[^/]+$", "/tmp")
  return tmpDir .. "/" .. SESSION_WAV_NAME, tmpDir .. "/" .. SNAPSHOT_WAV_NAME
end

-- ───── lifecycle ────────────────────────────────────────────────────────────

--- Register the per-tick emission handler. Delegates to the infer module,
--- which owns the dispatch. Kept on this surface so the only caller
--- (dikta-stream-mode) is unaffected by the module split.
--- @param fn function|nil Handler invoked with each cleaned transcript string.
function M.setEmissionHandler(fn)
  infer.setEmissionHandler(fn)
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
  local snapshotWav
  sessionWav, snapshotWav = deriveScratchPaths(streamSh)
  local ffmpegPath = ffmpeg.resolve(cfg and cfg.ffmpeg_path)
  infer.configure({ffmpegPath = ffmpegPath,
                   sessionWav = sessionWav,
                   snapshotWav = snapshotWav})
  infer.resetDedup()
  -- The mic picker is the source of truth for which input ffmpeg records
  -- from. Read at session start (not module load) so menu changes take
  -- effect on the next PTT without hs.reload(). Pass as the 2nd
  -- positional arg to stream.sh's `record` subcommand, which accepts
  -- `record <wav-path> [device]`.
  local audioDevice = mic.loadAudioDevice()
  print(string.format("[dk-stream] start: audio_device=%s", audioDevice))
  os.remove(sessionWav)
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
      -- inside infer.finalize prevents a no-op flash when the final pass
      -- matches the last live emission. The pendingOnDone hook (set by
      -- M.stop) is invoked after the final emission dispatches so the
      -- caller can tear down the splice with the transcript already pasted.
      local cb = pendingOnDone
      pendingOnDone = nil
      infer.finalize(cb)
    end,
    {"record", sessionWav, audioDevice})
  ffmpegTask:start()
  pollTimer = hs.timer.doEvery(POLL_INTERVAL_S, infer.pollOnce)
  isStreaming = true
  print("[dk-stream] start: end")
  return true
end

--- Tear down the pipeline: stop the timer, mark not-streaming so any
--- in-flight poll bails, then SIGTERM ffmpeg. The recorder's exit callback
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
