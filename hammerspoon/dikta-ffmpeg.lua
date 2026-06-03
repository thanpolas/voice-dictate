--- @fileoverview ffmpeg binary location — shared by the mic picker and the
--- streaming pipeline.
---
--- Hammerspoon launches from launchd with a minimal PATH and cannot look up
--- `ffmpeg` itself; the Homebrew prefix also differs between Apple Silicon
--- (/opt/homebrew) and Intel (/usr/local). install.sh resolves the absolute
--- path at install time and writes it as cfg.ffmpeg_path; this module turns
--- that (possibly absent, for configs predating the key) into a usable path.
---
--- Public API:
---   M.resolve(fromCfg)  Return the absolute ffmpeg path to use.

local M = {}

-- ───── constants ────────────────────────────────────────────────────────────

--- The two Homebrew prefixes probed (in order) when cfg.ffmpeg_path is absent
--- or stale: Apple Silicon first, then Intel.
local HOMEBREW_FFMPEG_PATHS = {"/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"}

-- ───── helpers ──────────────────────────────────────────────────────────────

--- Test whether a filesystem path is readable. Used to probe the candidate
--- ffmpeg locations.
--- @param path string Absolute filesystem path.
--- @return boolean True iff the path opens for reading.
local function pathExists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

-- ───── public API ─────────────────────────────────────────────────────────────

--- Pick an ffmpeg location: the explicit cfg value wins when it points at a
--- readable file, otherwise probe the two common Homebrew prefixes (Apple
--- Silicon then Intel). Last-resort returns the Apple Silicon path so the
--- caller's hs.task / hs.execute surfaces a clear "no such file" exit rather
--- than this module crashing on load.
--- @param fromCfg string|nil Value from cfg.ffmpeg_path, may be nil.
--- @return string Absolute ffmpeg path.
function M.resolve(fromCfg)
  if fromCfg and fromCfg ~= "" and pathExists(fromCfg) then return fromCfg end
  for _, p in ipairs(HOMEBREW_FFMPEG_PATHS) do
    if pathExists(p) then
      print(string.format(
        "[dk-ffmpeg] ffmpeg_path not in config; falling back to %s — re-run ./install.sh to lock it in",
        p))
      return p
    end
  end
  return HOMEBREW_FFMPEG_PATHS[1]
end

return M
