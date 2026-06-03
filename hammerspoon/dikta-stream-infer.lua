--- @fileoverview Streaming inference cycle — turn the session WAV into emissions.
---
--- Owns the per-tick mechanics only: finalise an ffmpeg snapshot of the
--- in-progress session WAV (whisper-server cannot parse the live file until
--- ffmpeg writes the WAV trailer), POST it to the daemon's /inference
--- endpoint, parse the JSON, and dispatch the full transcript as a single
--- emission to the registered handler. Knows nothing about hotkeys, the
--- recorder process, or the poll timer — those live in dikta-stream.lua, which
--- configures this module per session and drives pollOnce()/finalize().
---
--- Because each transcript is the model's reading of the *entire* session WAV
--- up to that tick, the downstream splice's substring-replace mechanic handles
--- revisions: prior transcript is the anchor, new transcript replaces it. A
--- dedup guard suppresses re-firing on an unchanged transcript; an in-flight
--- guard prevents a second concurrent inference while one is pending.
---
--- Public API:
---   M.configure(opts)         Set per-session ffmpegPath + sessionWav + snapshotWav.
---   M.setEmissionHandler(fn)  Register the per-tick handler. Default no-op.
---   M.resetDedup()            Clear dedup + in-flight state at session start.
---   M.pollOnce()              One live poll: snapshot → POST → dispatch.
---   M.finalize(onDone)        Post-stop final pass against the flushed WAV.

local M = {}

-- ───── constants ────────────────────────────────────────────────────────────

--- HTTP endpoint the daemon serves. Port matches stream-server.sh's default.
local SERVER_URL = "http://127.0.0.1:8472/inference"

--- Absolute path to system curl. Stable across every macOS install
--- (system-provided, not Homebrew). Named here per A2 — no inline literals
--- at hs.task call sites.
local CURL_BIN = "/usr/bin/curl"

-- ───── module state ─────────────────────────────────────────────────────────

--- Absolute path to the ffmpeg binary, set by M.configure from the lifecycle
--- module (which resolves it via dikta-ffmpeg). Nil until configured.
local ffmpegPath = nil

--- Absolute paths to the session WAV (continuous capture, read-only here) and
--- the per-tick snapshot this module writes + POSTs. Set by M.configure.
local sessionWav = nil
local snapshotWav = nil

--- Last transcript text dispatched downstream — a dedup guard so identical
--- successive polls don't re-fire the handler for no change.
local lastDispatchedText = ""

--- True while a poll cycle is in flight, so the next tick doesn't queue a
--- second concurrent inference while inference for the prior is pending.
local pollInFlight = false

--- Caller-registered handler invoked once per cleaned transcript.
local onEmission = function(_line) end

-- ───── configuration ────────────────────────────────────────────────────────

--- Set the per-session inputs. Called by dikta-stream.lua's M.start once the
--- ffmpeg path and scratch WAV paths are resolved for this session.
--- @param opts table {ffmpegPath, sessionWav, snapshotWav} — all required.
function M.configure(opts)
  ffmpegPath = opts.ffmpegPath
  sessionWav = opts.sessionWav
  snapshotWav = opts.snapshotWav
end

--- Register the per-tick emission handler. Default is a no-op so the module
--- ships callable on its own; dikta-stream-mode wires the splice through the
--- lifecycle module, which delegates here.
--- @param fn function|nil Handler invoked with each cleaned transcript string.
function M.setEmissionHandler(fn)
  onEmission = fn or function(_line) end
end

--- Clear the dedup + in-flight guards. Called at session start so a new
--- session never suppresses its first emission as a "dup" of the last one.
function M.resetDedup()
  lastDispatchedText = ""
  pollInFlight = false
end

-- ───── poll cycle ───────────────────────────────────────────────────────────

--- POST the snapshot WAV to whisper-server and dispatch the parsed transcript.
--- Runs after the snapshot finalisation step completes successfully.
local function postSnapshot()
  local task = hs.task.new(CURL_BIN,
    function(exit, stdout, _stderr)
      pollInFlight = false
      if exit ~= 0 then
        print(string.format("[dk-infer] skip: curl exit=%d", exit))
        return
      end
      if stdout == nil or stdout == "" then
        print("[dk-infer] skip: empty stdout")
        return
      end
      local ok, parsed = pcall(hs.json.decode, stdout)
      if not ok or type(parsed) ~= "table" or type(parsed.text) ~= "string" then
        print("[dk-infer] skip: bad json")
        return
      end
      local text = parsed.text:gsub("^%s+", ""):gsub("%s+$", "")
      if text == "" then
        print("[dk-infer] skip: empty text")
        return
      end
      if text == lastDispatchedText then
        print("[dk-infer] skip: dup")
        return
      end
      lastDispatchedText = text
      print(string.format("[dk-infer] emit: %s", text))
      onEmission(text)
    end,
    {"-s", "-F", "file=@" .. snapshotWav, SERVER_URL})
  task:start()
end

--- One live poll: finalise the in-progress session WAV into a snapshot the
--- server can parse, then chain into the POST. Two hs.task spawns (snapshot,
--- POST) so neither blocks the Hammerspoon main thread. No-op if a prior poll
--- is still in flight.
function M.pollOnce()
  if pollInFlight then
    print("[dk-infer] skip: poll in flight")
    return
  end
  pollInFlight = true
  local task = hs.task.new(ffmpegPath,
    function(exit, _stdout, _stderr)
      if exit ~= 0 then
        print(string.format("[dk-infer] skip: snapshot exit=%d", exit))
        pollInFlight = false
        return
      end
      postSnapshot()
    end,
    {"-hide_banner", "-loglevel", "error", "-y",
     "-i", sessionWav, "-c", "copy", snapshotWav})
  task:start()
end

--- Final-pass transcription fired by the recorder's exit callback after stop.
--- Runs unconditionally on stop: ffmpeg has now flushed the WAV trailer so the
--- snapshot+POST succeeds where the live-poll path may have failed with
--- AVERROR_INVALIDDATA (exit 183) early in the session, AND captures the 1-2s
--- tail of audio between the last live poll and the PTT release that would
--- otherwise be lost. The result is dispatched through onEmission (still the
--- splice handler until the caller's onDone runs), so even utterances shorter
--- than the live-poll's first-success threshold paste a transcript, and longer
--- ones get their tail captured. Dedup prevents a no-op flash when the final
--- pass exactly matches the last emission.
--- @param onDone function|nil Invoked after dispatch (success or failure) so
---                            the caller can tear down (e.g. splice.stopSession).
function M.finalize(onDone)
  print("[dk-infer] finalize: begin")
  hs.task.new(ffmpegPath,
    function(exit, _stdout, _stderr)
      if exit ~= 0 then
        print(string.format("[dk-infer] finalize: snapshot exit=%d", exit))
        os.remove(snapshotWav)
        if onDone then onDone() end
        return
      end
      hs.task.new(CURL_BIN,
        function(curlExit, stdout, _curlStderr)
          if curlExit ~= 0 then
            print(string.format("[dk-infer] finalize: curl exit=%d", curlExit))
          elseif stdout == nil or stdout == "" then
            print("[dk-infer] finalize: empty stdout")
          else
            local ok, parsed = pcall(hs.json.decode, stdout)
            if not ok or type(parsed) ~= "table" or type(parsed.text) ~= "string" then
              print("[dk-infer] finalize: bad json")
            else
              local text = parsed.text:gsub("^%s+", ""):gsub("%s+$", "")
              if text == "" then
                print("[dk-infer] finalize: empty text")
              elseif text == lastDispatchedText then
                print("[dk-infer] finalize: dup")
              else
                lastDispatchedText = text
                print(string.format("[dk-infer] finalize emit: %s", text))
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

return M
