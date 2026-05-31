--- @fileoverview Rolling-window → full-transcript merge adapter for the
--- experimental whisper-stream engine. whisper-stream emits the transcript of
--- the last STREAM_LENGTH_MS of audio on every step, so consecutive windows
--- overlap heavily and a single window is NOT the full transcript. This pure
--- module reconstructs one growing transcript the splice layer can treat as
--- full-text-so-far: it appends only the genuinely-new tail of each window,
--- found via the longest overlap between the end of the accumulated text and
--- the start of the new window.
---
--- Append-only by design (plan D3): committed words are never rewritten, so a
--- mid-window revision by the model is not reflected. That is the accepted
--- lossy trade-off for this experimental engine — rewriting committed text
--- loses content with this model (see the streaming history, commit 5dd0951).
--- Word-level (not byte-level) overlap so multibyte UTF-8 is never cut mid-rune.
---
--- Pure — no hs.* dependency. Public API:
---   M.new()              A fresh accumulator (opaque table).
---   M.push(acc, window)  Merge a window; return the full transcript so far.

local M = {}

-- ───── helpers ────────────────────────────────────────────────────────────────

--- Split a transcript fragment into whitespace-delimited words.
--- @param s string A cleaned window transcript.
--- @return table Array of word strings.
local function splitWords(s)
  local words = {}
  for word in s:gmatch("%S+") do words[#words + 1] = word end
  return words
end

--- True iff the last k words of acc equal the first k words of win — the
--- overlap test that finds where a new window restates already-committed text.
--- @param acc table Accumulated words.
--- @param win table New window words.
--- @param k number Overlap length to test.
--- @return boolean
local function tailMatchesHead(acc, win, k)
  for i = 1, k do
    if acc[#acc - k + i] ~= win[i] then return false end
  end
  return true
end

--- Longest k (largest first) for which acc's tail matches win's head, or 0.
--- @param acc table Accumulated words.
--- @param win table New window words.
--- @return number The overlap length, 0 when the window shares no boundary.
local function overlapLength(acc, win)
  for k = math.min(#acc, #win), 1, -1 do
    if tailMatchesHead(acc, win, k) then return k end
  end
  return 0
end

-- ───── public API ─────────────────────────────────────────────────────────────

--- A fresh accumulator — the committed words plus the last full string.
--- @return table A new accumulator for M.push.
function M.new()
  return {words = {}, fullText = ""}
end

--- Merge a window into the accumulator and return the full transcript so far.
--- Appends only the window words past the overlap; no overlap appends them all.
--- @param acc table An accumulator from M.new().
--- @param window string The latest cleaned window transcript.
--- @return string The full transcript so far.
function M.push(acc, window)
  local win = splitWords(window)
  local words = acc.words
  for i = overlapLength(words, win) + 1, #win do
    words[#words + 1] = win[i]
  end
  acc.fullText = table.concat(words, " ")
  return acc.fullText
end

return M
