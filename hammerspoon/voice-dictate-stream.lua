--- @fileoverview Opt-in streaming dictation — long-lived whisper-stream + splice.
---
--- Owns the streaming pipeline that is sibling to voice-dictate.lua's single-shot
--- record-then-transcribe path. A long-lived bin/stream.sh task emits one
--- transcription line every STREAM_STEP_MS over the rolling audio window; this
--- module consumes those lines and pastes them into the focused field via the
--- clipboard-mediated splice described in the streaming-transcription plan.
---
--- This file is step 4 of the plan: the wiring — spawn the task, consume stdout
--- line-by-line, log emissions. Step 5 adds the splice paste layer on top of
--- the seam established here. Step 6 wires the streaming hotkey through the
--- main module so M.start()/M.stop() compose with single-shot.
---
--- Public API:
---   M.start(cfg)   Spawn bin/stream.sh; subscribe to emissions. Idempotent.
---   M.stop()       Kill the task; reset state. Safe to repeat.
---   M.isStreaming() Read current state; used by the menubar dropdown.

local M = {}

-- ───── constants ────────────────────────────────────────────────────────────

--- Default path to the streaming shell entry point. Overridden by cfg.stream_sh
--- when M.start() is called with an explicit config (install.sh writes the
--- absolute path into voice-dictate-config.lua just as it does dictate_sh).
local DEFAULT_STREAM_SH = os.getenv("HOME") ..
  "/Projects/myStash/voice-dictate/bin/stream.sh"

--- Marker whisper-stream prints to stderr when it is ready for audio input.
--- Stripped from any emission line that surfaces it so the splice layer never
--- sees binary noise as user-visible text.
local READY_MARKER = "%[Start speaking%]"

-- ───── module state ─────────────────────────────────────────────────────────

--- True between M.start() and M.stop(); read by the menubar dropdown.
local isStreaming = false

--- The hs.task running bin/stream.sh. Nil when idle.
local streamTask = nil

--- Optional caller-supplied hook invoked once per emission line. Step 5
--- replaces the default no-op with the splice paste handler. Kept as a setter
--- so step 5 can land without re-shaping the start() signature.
local onEmission = function(_line) end

-- ───── stdout consumption ───────────────────────────────────────────────────

--- Strip ANSI/VT100 escape sequences. Whisper-stream renders its output
--- in-place with CSI codes (`\e[2K` clear-line, `\e[0;…` colour resets, …);
--- the ESC byte is invisible in most consoles but the bracketed payload
--- leaks into our emissions and (a) breaks Lua patterns when `[` appears
--- without a `]`, (b) shows up as garbage if pasted. Covers CSI, OSC,
--- charset designation, and 2-byte ESC <letter>.
--- @param s string Raw line possibly containing ANSI escapes.
--- @return string Same line with the escapes removed.
local function stripAnsi(s)
  return (s
    :gsub("\27%[[%d;?]*[a-zA-Z]", "")
    :gsub("\27%]%d+;[^\7\27]*\7", "")
    :gsub("\27[%(%)%*%+][A-Za-z0-9]", "")
    :gsub("\27[A-Za-z=>]", "")
  )
end

--- Strip the [Start speaking] readiness marker, ANSI escapes, leading/trailing
--- whitespace, and any whisper-stream non-speech markers (`[BLANK_AUDIO]`,
--- `(silence)`, `(soft music)`, etc.). Returns nil when nothing useful remains.
--- Skipping markers at this layer means the splice layer's "first emission"
--- detection (lastPastedDictationText == "") stays accurate — a non-speech
--- marker pasted as the first emission would otherwise commit garbage and push
--- subsequent splice cycles down the Shift+Cmd+Up path on a still-empty field.
--- @param raw string One line of whisper-stream stdout as Hammerspoon delivered it.
--- @return string|nil The cleaned emission, or nil if the line is empty / marker-only.
local function cleanEmission(raw)
  local clean = stripAnsi(raw)
  clean = clean:gsub(READY_MARKER, "")
  clean = clean:gsub("^%s+", ""):gsub("%s+$", "")
  -- Strip a line that is entirely bracketed/parenthesized markers + punctuation:
  -- remove all [..] and (..) blocks, then any leftover whitespace and dots.
  -- If nothing remains, the line was a non-speech artefact.
  local residue = clean:gsub("%b[]", ""):gsub("%b()", ""):gsub("[%s%.]+", "")
  if residue == "" then return nil end
  return clean
end

--- Stream callback wired into hs.task. Fires per chunk of stdout, which may
--- contain multiple emission lines glued together; split on newline and
--- forward each non-empty cleaned line to onEmission(). Returning true keeps
--- the task running and the stream open.
--- @param _task table The hs.task instance (unused — we have a module-level handle).
--- @param stdOut string Chunk of stdout since the last callback.
--- @param _stdErr string Chunk of stderr since the last callback (logged only).
--- @return boolean Always true — never close the stream from this side.
local function onStdout(_task, stdOut, _stdErr)
  if not stdOut or stdOut == "" then return true end
  for line in stdOut:gmatch("[^\r\n]+") do
    local clean = cleanEmission(line)
    if clean then
      print("[vd-stream] emit: " .. clean)
      onEmission(clean)
    else
      print("[vd-stream] skip: " .. line)
    end
  end
  return true
end

--- Exit callback wired into hs.task. Fires when whisper-stream actually
--- terminates — either because the user toggled off (M.stop) or because the
--- binary crashed. Resets state regardless of cause so the next M.start() is
--- a clean spawn.
--- @param exitCode number Process exit code; 0 on clean kill, non-zero on crash.
--- @param _stdOut string Final stdout chunk (already streamed via onStdout).
--- @param stdErr string Final stderr chunk (logged on non-zero exit).
local function onExit(exitCode, _stdOut, stdErr)
  if exitCode ~= 0 and exitCode ~= 15 then -- 15 == SIGTERM, expected on M.stop
    print(string.format("[vd-stream] whisper-stream exit=%s stderr=%q",
      tostring(exitCode), tostring(stdErr)))
  end
  streamTask = nil
  isStreaming = false
end

-- ───── public API ───────────────────────────────────────────────────────────

--- Install a per-emission handler. The default is a no-op so step 4 ships a
--- runnable wiring layer; step 5's splice paste layer registers itself here.
--- @param fn function Called as fn(line: string) for every cleaned emission.
function M.setEmissionHandler(fn)
  onEmission = fn or function(_line) end
end

--- Spawn bin/stream.sh and start consuming its stdout. No-op if already
--- streaming. Idempotent in the sense that double-start has no extra effect;
--- the caller is expected to M.stop() first if they want a fresh process.
--- @param cfg table Optional config with .stream_sh; falls back to DEFAULT_STREAM_SH.
--- @return boolean True if a new task was started; false if already streaming.
function M.start(cfg)
  if isStreaming then return false end
  local streamSh = (cfg and cfg.stream_sh) or DEFAULT_STREAM_SH
  streamTask = hs.task.new(streamSh, onExit, onStdout, {"stream"})
  if not streamTask:start() then
    print("[vd-stream] failed to start " .. streamSh)
    streamTask = nil
    return false
  end
  isStreaming = true
  return true
end

--- Kill the streaming task and reset state. Safe to call repeatedly. The
--- onExit callback fires on the task's actual exit and finishes state cleanup
--- there — this function only requests termination.
function M.stop()
  if streamTask then
    streamTask:terminate()
    -- onExit clears streamTask + flips isStreaming when whisper-stream exits.
  else
    isStreaming = false
  end
end

--- Read current state. Used by the menubar dropdown and by M.start() to guard
--- against double-spawn from chord overlap.
--- @return boolean True iff a streaming session is active.
function M.isStreaming()
  return isStreaming
end

return M
