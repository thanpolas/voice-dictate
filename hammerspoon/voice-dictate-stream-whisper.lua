--- @fileoverview EXPERIMENTAL whisper-stream streaming engine — the opt-in
--- alternative to the stable ffmpeg + whisper-server engine
--- (voice-dictate-stream.lua). Spawns bin/stream-whisper.sh, consumes the
--- rolling transcription windows it prints on stdout, reconstructs one growing
--- transcript via voice-dictate-whisper-merge, and dispatches it to the
--- registered handler. Satisfies the SAME engine contract as
--- voice-dictate-stream.lua so voice-dictate-stream-mode can drive either:
---   M.setEmissionHandler(fn)  Register the per-window full-text handler.
---   M.start(cfg)              Spawn the recorder, subscribe to stdout. Idempotent.
---   M.stop(onDone)            Terminate; onDone fires after the process exits.
---   M.isStreaming()           Query state.
---
--- WHY EXPERIMENTAL: SDL2 capture bypasses Apple's Voice Processing IO unit and
--- can hallucinate on mics that need that DSP — see the pluggable-engines plan.
--- Unlike the ffmpeg engine there is no post-stop final pass, so the up-to-one
--- step of audio between the last window and SIGTERM is dropped.

local M = {}

--- Rolling-window → full-transcript merge adapter (pure). See its @fileoverview.
local merge = require("voice-dictate-whisper-merge")

--- Settings store — supplies the SDL2 capture device id, read at session start.
local settings = require("voice-dictate-settings")

-- ───── constants ────────────────────────────────────────────────────────────

--- Repo-derived path to bin/stream-whisper.sh. The streaming-mode caller's cfg
--- overrides this when set (install.sh writes the absolute path into the config).
local DEFAULT_STREAM_WHISPER_SH = os.getenv("HOME") ..
  "/Projects/myStash/voice-dictate/bin/stream-whisper.sh"

--- SDL2 capture device id used when the Settings SDL2 picker has stored nothing.
--- SDL2 numbering is independent of the avfoundation mic index, so the existing
--- Microphone picker does not apply to this engine.
local DEFAULT_CAPTURE_ID = "-1"

--- The recorder subcommand. Named per A2 — no inline literal at the call site.
local SUBCMD_STREAM = "stream"

--- whisper-stream's readiness marker, stripped from any window that surfaces it
--- so the merge adapter never treats console chrome as transcript text.
local READY_MARKER = "%[Start speaking%]"

--- Log prefix for this engine's Console lines (A2 — single repeat-use literal).
local LOG_PREFIX = "[vd-whisper]"

--- Process exit code for SIGTERM — the expected code when M.stop terminates the
--- recorder, distinguished from a genuine crash so we don't log a false error.
local SIGTERM_EXIT = 15

-- ───── module state ───────────────────────────────────────────────────────────

--- True between M.start() and the recorder's exit; read by streamMode.isActive().
local isStreaming = false

--- The hs.task running bin/stream-whisper.sh. Nil when idle.
local streamTask = nil

--- Caller-registered handler invoked once per dispatched full transcript.
local onEmission = function(_text) end

--- Callback fired after the recorder exits and state is reset. Set by M.stop,
--- invoked by the exit callback. Nil between sessions.
local pendingOnDone = nil

--- Merge accumulator for the current session; fresh per M.start. Nil when idle.
local acc = nil

--- Last full transcript dispatched — dedup guard so an unchanged window (a
--- re-render that added nothing) does not re-fire the splice.
local lastDispatchedText = ""

-- ───── stdout cleaning ──────────────────────────────────────────────────────

--- Strip ANSI / VT100 escape sequences. whisper-stream renders in place with
--- CSI codes (clear-line, colour resets); the ESC byte is invisible in most
--- consoles but the bracketed payload breaks Lua patterns and shows as garbage
--- if pasted. Covers CSI, OSC, charset designation, and 2-byte ESC <letter>.
--- @param s string Raw line possibly containing ANSI escapes.
--- @return string The line with escapes removed.
local function stripAnsi(s)
  return (s
    :gsub("\27%[[%d;?]*[a-zA-Z]", "")
    :gsub("\27%]%d+;[^\7\27]*\7", "")
    :gsub("\27[%(%)%*%+][A-Za-z0-9]", "")
    :gsub("\27[A-Za-z=>]", "")
  )
end

--- Strip ANSI, the readiness marker, surrounding whitespace, and non-speech
--- markers (`[BLANK_AUDIO]`, `(silence)`, …). Returns nil when nothing useful
--- remains, so the merge adapter never ingests a marker-only window.
--- @param raw string One raw line of whisper-stream stdout.
--- @return string|nil The cleaned window, or nil if empty / marker-only.
local function cleanEmission(raw)
  local clean = stripAnsi(raw)
  clean = clean:gsub(READY_MARKER, ""):gsub("^%s+", ""):gsub("%s+$", "")
  local residue = clean:gsub("%b[]", ""):gsub("%b()", ""):gsub("[%s%.]+", "")
  if residue == "" then return nil end
  return clean
end

-- ───── dispatch ─────────────────────────────────────────────────────────────

--- Clean one raw window, merge it into the running transcript, and dispatch the
--- full text to the handler. Skips marker-only lines and no-op windows that
--- added nothing new (dedup against the last dispatch).
--- @param raw string One line of whisper-stream stdout.
local function dispatchWindow(raw)
  local clean = cleanEmission(raw)
  if not clean then
    print(LOG_PREFIX .. " skip: " .. raw)
    return
  end
  local fullText = merge.push(acc, clean)
  if fullText == "" or fullText == lastDispatchedText then return end
  lastDispatchedText = fullText
  print(LOG_PREFIX .. " emit: " .. fullText)
  onEmission(fullText)
end

-- ───── task callbacks ───────────────────────────────────────────────────────

--- hs.task stream callback. Fires per stdout chunk, which may glue several
--- windows together; split on CR/LF and dispatch each. Returning true keeps the
--- stream open. Partial lines are harmless — the next fuller window's overlap
--- absorbs them via the merge adapter.
--- @param _task table The hs.task instance (unused — module-level handle).
--- @param stdOut string Chunk of stdout since the last callback.
--- @param _stdErr string Chunk of stderr (unused here).
--- @return boolean Always true — never close the stream from this side.
local function onStdout(_task, stdOut, _stdErr)
  if not stdOut or stdOut == "" then return true end
  for line in stdOut:gmatch("[^\r\n]+") do
    dispatchWindow(line)
  end
  return true
end

--- hs.task exit callback. Fires when whisper-stream terminates (M.stop or a
--- crash). Resets state, then fires any pending onDone so the orchestrator can
--- tear down the splice. SIGTERM (the M.stop path) is not logged as an error.
--- @param exitCode number Process exit code.
--- @param _stdOut string Final stdout chunk (already streamed via onStdout).
--- @param stdErr string Final stderr chunk (logged on a genuine crash).
local function onExit(exitCode, _stdOut, stdErr)
  if exitCode ~= 0 and exitCode ~= SIGTERM_EXIT then
    print(string.format("%s whisper-stream exit=%s stderr=%q",
      LOG_PREFIX, tostring(exitCode), tostring(stdErr)))
  end
  streamTask = nil
  isStreaming = false
  local cb = pendingOnDone
  pendingOnDone = nil
  if cb then cb() end
end

-- ───── public API ───────────────────────────────────────────────────────────

--- Register the per-window emission handler. Default no-op so the module ships
--- callable on its own; voice-dictate-stream-mode wires the splice.
--- @param fn function|nil Called as fn(fullText) for each dispatched transcript.
function M.setEmissionHandler(fn)
  onEmission = fn or function(_text) end
end

--- Spawn the whisper-stream recorder and start consuming its stdout. No-op if
--- already streaming. Resets the merge accumulator so each session starts from
--- an empty transcript.
--- @param cfg table Optional config; .stream_whisper_sh overrides the path.
--- @return boolean True if a new task started; false if already streaming / failed.
function M.start(cfg)
  if isStreaming then
    print(LOG_PREFIX .. " start: skip (already streaming)")
    return false
  end
  local streamWhisperSh = (cfg and cfg.stream_whisper_sh) or DEFAULT_STREAM_WHISPER_SH
  -- Read the SDL2 device at session start (not module load) so a menu change
  -- applies on the next dictation without hs.reload(), like the mic picker.
  local captureId = settings.get(settings.SETTING.SDL2_CAPTURE_ID) or DEFAULT_CAPTURE_ID
  acc = merge.new()
  lastDispatchedText = ""
  streamTask = hs.task.new(streamWhisperSh, onExit, onStdout,
    {SUBCMD_STREAM, captureId})
  if not streamTask:start() then
    print(LOG_PREFIX .. " start: failed to launch " .. streamWhisperSh)
    streamTask = nil
    return false
  end
  isStreaming = true
  print(string.format("%s start: streaming (capture=%s)", LOG_PREFIX, captureId))
  return true
end

--- Terminate the recorder. The exit callback resets state and fires onDone, so
--- onDone runs after the process is actually gone. There is no final pass — the
--- last live window is the last emission. Safe to call when idle.
--- @param onDone function|nil Fires once the recorder has exited.
function M.stop(onDone)
  if streamTask then
    pendingOnDone = onDone
    streamTask:terminate()
  else
    isStreaming = false
    if onDone then onDone() end
  end
end

--- Query state.
--- @return boolean True iff a streaming session is currently active.
function M.isStreaming()
  return isStreaming
end

return M
