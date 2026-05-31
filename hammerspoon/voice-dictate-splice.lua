--- @fileoverview Clipboard-mediated splice — paste each pipeline emission
--- into the focused field via Shift+Cmd+Up / Cmd+X / modify clipboard / Cmd+V.
--- Sibling of voice-dictate-stream.lua: stream.lua dispatches each cleaned
--- transcript as an emission; this module turns emissions into paste cycles
--- while preserving the user's clipboard across the session and stopping on
--- focus loss.
---
--- Public API: M.startSession(cfg), M.applyEmission(line), M.stopSession(),
--- M.setOnStop(fn), M.isActive().

local M = {}

-- ───── constants ────────────────────────────────────────────────────────────

--- Milliseconds to wait after Cmd+X before reading the pasteboard. NSPasteboard
--- writes asynchronously to its delegate; 80ms is generous on Apple Silicon
--- without making the cycle feel sluggish at the 500ms step default.
local CUT_SETTLE_MS = 80

--- Milliseconds to wait after Cmd+V before the next splice cycle can fire.
--- Prevents the next emission from racing into the field before the paste
--- has actually landed.
local PASTE_SETTLE_MS = 40

--- Seconds to wait after stopSession() before restoring the pre-session
--- clipboard. The most recent spliceCycle synthesized a Cmd+V that needs
--- time to land in the target app; restoring too quickly races with the
--- paste handler in slower apps (Slack, browser textareas) and the user
--- sees the pre-session clipboard contents pasted in place of the
--- transcript. 400ms is comfortable for every app we've tested.
local PASTEBOARD_RESTORE_DELAY_S = 0.4

-- ───── module state ─────────────────────────────────────────────────────────

--- True between startSession() and stopSession(); read by stream.lua.
local isActive = false

--- Committed prefix prepended to every emission before pasting. Always
--- empty under the ffmpeg + whisper-server pipeline because each emission
--- is the full transcript of the session so far; kept as a hook for a
--- future windowing strategy that would commit stable prefixes.
local committedPrefix = ""

--- Full dictation text last pasted into the field; the splice's anchor
--- substring for D3 (divergence skip on user-edited text).
local lastPastedDictationText = ""

--- Clipboard contents at startSession() — restored on stopSession (D4).
local pasteboardSnapshot = nil

--- hs.window.filter handle subscribed for focus-change events.
local focusFilter = nil

--- True when emissions should append at the cursor rather than splice-
--- replace the prior paste. The current pipeline (ffmpeg + whisper-server)
--- emits full revisions, so stream-mode forces this to false; the append
--- branch survives as a fallback for callers passing append_only = true.
local appendOnly = false

--- Caller hook fired when focus-loss policy (D6) self-stops the session.
local onStop = function() end

-- ───── helpers ──────────────────────────────────────────────────────────────

--- Pause for `ms` milliseconds. hs.timer.usleep takes microseconds; this is
--- the readable wrapper used by the keystroke chain.
--- @param ms number Milliseconds to sleep.
local function sleepMs(ms)
  hs.timer.usleep(ms * 1000)
end

--- Synthesize the select-to-start-of-document keystroke for native macOS
--- text views. On single-line fields it collapses to select-to-start-of-line,
--- which still covers anything the splice could have pasted there.
local function selectToStart()
  hs.eventtap.keyStroke({"shift", "cmd"}, "up", 0)
end

--- Cut the current selection to the system pasteboard. On empty selection
--- this is a no-op and preserves the clipboard — we rely on the caller to
--- have just synthesized selectToStart() so a selection exists.
local function cutSelection()
  hs.eventtap.keyStroke({"cmd"}, "x", 0)
  sleepMs(CUT_SETTLE_MS)
end

--- Paste current clipboard contents. Trailing sleep prevents the next splice
--- cycle from racing in before the field actually shows the new text.
local function pasteClipboard()
  hs.eventtap.keyStroke({"cmd"}, "v", 0)
  sleepMs(PASTE_SETTLE_MS)
end

-- ───── splice / append paths ────────────────────────────────────────────────

--- Run one full splice cycle against the focused field. Returns true on a
--- successful replace; false if D3's divergence skip fired (user edited the
--- text mid-stream and our anchor substring is gone). On false, the cut
--- contents are written back and pasted so the user's edit is preserved.
---
--- On the *first* emission of a session, lastPastedDictationText is empty
--- and there is nothing of ours in the field to splice over. We skip the
--- Shift+Cmd+Up + Cmd+X dance entirely and just paste at the cursor.
--- Avoids triggering apps that interpret Shift+Cmd+Up on an empty prompt
--- as "load previous history" (Claude Code's input, most REPLs).
--- @param emission string Cleaned pipeline emission for this cycle.
--- @return boolean True if the splice landed; false on divergence skip.
local function spliceCycle(emission)
  local newFullText = committedPrefix .. emission
  if lastPastedDictationText == "" then
    hs.pasteboard.setContents(newFullText)
    pasteClipboard()
    lastPastedDictationText = newFullText
    return true
  end
  selectToStart()
  cutSelection()
  local cut = hs.pasteboard.getContents() or ""
  local startIdx, endIdx = cut:find(lastPastedDictationText, 1, true)
  if not startIdx then
    hs.pasteboard.setContents(cut)
    pasteClipboard()
    return false
  end
  -- Concat-based splice rather than gsub so pattern magic in the anchor
  -- (e.g. an unmatched `[` left over from ANSI noise, or a literal `%`)
  -- can never break the replace.
  local swapped = cut:sub(1, startIdx - 1) .. newFullText .. cut:sub(endIdx + 1)
  hs.pasteboard.setContents(swapped)
  pasteClipboard()
  lastPastedDictationText = newFullText
  return true
end

--- Append-only emission: paste the new content at the cursor without
--- selecting / cutting / replacing. Fallback path retained for callers
--- whose emission stream is not a stable full revision — e.g. a future
--- delta-only backend, or the historical whisper-stream rolling window
--- where successive emissions were disjoint transcripts of overlapping
--- audio. Under the current ffmpeg + whisper-server pipeline each
--- emission is the full transcript, so stream-mode forces spliceCycle.
--- Inserts a single space when the previous paste did not end with
--- whitespace and the new emission does not start with one — so
--- accumulated text stays word-segmented.
--- @param emission string Cleaned pipeline emission for this cycle.
local function appendCycle(emission)
  local needsSpace = lastPastedDictationText ~= ""
    and not lastPastedDictationText:match("%s$")
    and not emission:match("^%s")
  local pasteText = needsSpace and (" " .. emission) or emission
  hs.pasteboard.setContents(pasteText)
  pasteClipboard()
  lastPastedDictationText = lastPastedDictationText .. pasteText
end

-- ───── focus-loss policy (D6) ───────────────────────────────────────────────

--- Stop the session in response to a focus change. Wires straight into the
--- module-level stopSession + the caller-supplied onStop hook so the
--- streaming task also dies. No-op if the session has already ended.
local function onFocusChanged()
  if not isActive then return end
  M.stopSession()
  onStop()
end

--- Subscribe to focus-changed events for the duration of the session.
--- Stored on focusFilter so unsubscribe can run from stopSession().
local function subscribeFocus()
  focusFilter = hs.window.filter.new()
  focusFilter:subscribe(hs.window.filter.windowFocused, onFocusChanged)
end

--- Unsubscribe focus events; release the filter handle so no callbacks
--- survive past the session.
local function unsubscribeFocus()
  if focusFilter then
    focusFilter:unsubscribeAll()
    focusFilter = nil
  end
end

-- ───── public API ───────────────────────────────────────────────────────────

--- Start a splice session. Snapshots the clipboard, resets state, subscribes
--- focus events. Idempotent — calling start while active is a no-op.
--- @param cfg table Optional config with .append_only.
function M.startSession(cfg)
  if isActive then return end
  pasteboardSnapshot = hs.pasteboard.getContents()
  committedPrefix = ""
  lastPastedDictationText = ""
  -- Default to append-only when the caller does not explicitly set it.
  -- The production caller (voice-dictate-stream-mode) always passes
  -- append_only = false because the ffmpeg + whisper-server pipeline
  -- emits full revisions; append survives as a safer fallback for any
  -- caller whose emissions are not stable revisions.
  if cfg ~= nil and cfg.append_only ~= nil then
    appendOnly = cfg.append_only
  else
    appendOnly = true
  end
  subscribeFocus()
  isActive = true
end

--- Dispatch one emission line through the configured cycle.
--- @param line string Cleaned pipeline emission.
function M.applyEmission(line)
  if not isActive or not line or line == "" then return end
  if appendOnly then appendCycle(line) else spliceCycle(line) end
end

--- Stop the session. Tears down focus + state immediately so any further
--- applyEmission calls no-op, then defers the pre-session clipboard
--- restore by PASTEBOARD_RESTORE_DELAY_S so the most recent spliceCycle's
--- synthetic Cmd+V has time to land in the target app. Restoring inline
--- races with slow paste handlers and causes the pre-session clipboard
--- to land in the field instead of the transcript. Safe to call repeatedly.
function M.stopSession()
  if not isActive then return end
  unsubscribeFocus()
  isActive = false
  committedPrefix = ""
  lastPastedDictationText = ""
  local snapshot = pasteboardSnapshot
  pasteboardSnapshot = nil
  if snapshot ~= nil then
    hs.timer.doAfter(PASTEBOARD_RESTORE_DELAY_S, function()
      hs.pasteboard.setContents(snapshot)
    end)
  end
end

--- Register the caller hook fired on focus-loss self-stop.
--- @param fn function Called with no arguments after stopSession() runs.
function M.setOnStop(fn)
  onStop = fn or function() end
end

--- Query session state. Used by the orchestrator and the menubar dropdown.
--- @return boolean True iff a splice session is currently active.
function M.isActive()
  return isActive
end

return M
