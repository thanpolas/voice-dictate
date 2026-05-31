--- @fileoverview Schema-driven settings store — a thin, typed wrapper over
--- hs.settings (NSUserDefaults) that generalises the persistence pattern
--- voice-dictate-mic.lua uses for the mic. Each setting is one SCHEMA row
--- declaring its NSUserDefaults key, human label, default, and (for enums) the
--- allowed choices plus their display labels. The menubar dropdown renders any
--- enum row as a checked-radio submenu, so future knobs slot in by adding a
--- row here — no bespoke menu wiring per switch.
---
--- Public API:
---   M.get(name)             Effective value for a setting, or its default.
---   M.set(name, value)      Persist a value (rejected if not an allowed choice).
---   M.choices(name)         Allowed values for an enum setting, in menu order.
---   M.choiceLabel(name, c)  Display label for one choice (menu text).
---   M.label(name)           Human label for the setting (submenu heading).
---   M.buildSettingsMenu()   The "Settings ▸" submenu descriptors for the menubar.

local M = {}

-- ───── engine identifiers ─────────────────────────────────────────────────────

--- Streaming-engine identifiers — code-stable values persisted as the "engine"
--- setting and compared by the orchestrator and menu (A2 — no magic strings at
--- call sites). FFMPEG_SERVER is the stable default (ffmpeg AVFoundation capture
--- + whisper-server daemon); WHISPER_STREAM is the opt-in experimental SDL2 path.
M.ENGINE = {
  FFMPEG_SERVER = "ffmpeg-server",
  WHISPER_STREAM = "whisper-stream",
}

-- ───── setting names ──────────────────────────────────────────────────────────

--- Public setting names — the keys callers pass to get/set. Held as constants
--- so consumers reference settings.SETTING.ENGINE, never a bare string literal.
M.SETTING = {
  ENGINE = "engine",
  SDL2_CAPTURE_ID = "sdl2_capture_id",
}

-- ───── schema ─────────────────────────────────────────────────────────────────

--- Declarative settings schema. One row per setting:
---   settings_key   NSUserDefaults key (namespaced; survives reload + reboot).
---   label          Human label, shown as the submenu heading.
---   default        Returned when nothing is stored, or a stale value is read.
---   choices        Allowed values (enum); absent for a free-form setting.
---   choice_labels  Display text per choice for the menu; falls back to the raw
---                  value when a choice has no entry.
---   visible_when    Optional predicate; the row is shown in the menu only when
---                  it returns true. Absent → always visible.
--- Adding a row here is all a new enum knob needs — the dropdown renders it.
local SCHEMA = {
  [M.SETTING.ENGINE] = {
    settings_key = "voice-dictate.engine",
    label = "Engine",
    default = M.ENGINE.FFMPEG_SERVER,
    choices = {M.ENGINE.FFMPEG_SERVER, M.ENGINE.WHISPER_STREAM},
    choice_labels = {
      [M.ENGINE.FFMPEG_SERVER] = "ffmpeg + whisper-server (stable)",
      [M.ENGINE.WHISPER_STREAM] = "whisper-stream + SDL2 — ⚠ experimental",
    },
  },
  [M.SETTING.SDL2_CAPTURE_ID] = {
    settings_key = "voice-dictate.sdl2CaptureId",
    label = "SDL2 capture device",
    default = "-1",
    choices = {"-1", "0", "1", "2", "3", "4"},
    -- SDL2 exposes no device names and any whisper-stream probe costs ~11s, so
    -- the picker offers raw integer ids (pick by trial), not enumerated names.
    choice_labels = {["-1"] = "Default (-1)"},
    -- Only meaningful for the whisper-stream engine — hidden under the stable
    -- ffmpeg engine, whose device comes from the Microphone (avfoundation) picker.
    visible_when = function()
      return M.get(M.SETTING.ENGINE) == M.ENGINE.WHISPER_STREAM
    end,
  },
}

-- ───── helpers ────────────────────────────────────────────────────────────────

--- True iff list contains value. Validates a stored or incoming value against
--- a setting's allowed choices.
--- @param list table Array of allowed values.
--- @param value any Value to look for.
--- @return boolean
local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then return true end
  end
  return false
end

-- ───── public API ─────────────────────────────────────────────────────────────

--- Effective value for a setting, or its default when nothing valid is stored.
--- A stored value that is no longer an allowed choice (e.g. the schema changed
--- under it) falls back to the default rather than propagating a stale value.
--- @param name string A settings.SETTING.* name.
--- @return any The effective value, or nil if the name is unknown.
function M.get(name)
  local row = SCHEMA[name]
  if not row then return nil end
  local stored = hs.settings.get(row.settings_key)
  if stored == nil then return row.default end
  if row.choices and not contains(row.choices, stored) then return row.default end
  return stored
end

--- Persist a value for a setting. Rejected with no write when the setting has a
--- choices list and the value is not in it, so the store can never hold a value
--- the schema does not recognise.
--- @param name string A settings.SETTING.* name.
--- @param value any The value to persist.
--- @return boolean True iff the value was accepted and written.
function M.set(name, value)
  local row = SCHEMA[name]
  if not row then return false end
  if row.choices and not contains(row.choices, value) then
    print(string.format(
      "[vd-settings] reject %s=%q — not an allowed choice", name, tostring(value)))
    return false
  end
  hs.settings.set(row.settings_key, value)
  return true
end

--- Allowed values for an enum setting, in the order the menu shows them.
--- @param name string A settings.SETTING.* name.
--- @return table|nil Array of allowed values, or nil for free-form / unknown.
function M.choices(name)
  local row = SCHEMA[name]
  return row and row.choices or nil
end

--- Display label for a single choice — the text the menu renders for it.
--- Falls back to the raw value when the schema gives no explicit label.
--- @param name string A settings.SETTING.* name.
--- @param choice any One of the setting's allowed values.
--- @return string Human-facing label.
function M.choiceLabel(name, choice)
  local row = SCHEMA[name]
  if row and row.choice_labels and row.choice_labels[choice] then
    return row.choice_labels[choice]
  end
  return tostring(choice)
end

--- Human label for a setting — the submenu heading.
--- @param name string A settings.SETTING.* name.
--- @return string|nil The label, or nil for an unknown setting.
function M.label(name)
  local row = SCHEMA[name]
  return row and row.label or nil
end

-- ───── menu ───────────────────────────────────────────────────────────────────

--- Enum settings surfaced in the dropdown's "Settings ▸" submenu, in display
--- order. Adding an enum knob means adding its SCHEMA row and its name here —
--- the menu reads this list and renders each as a checked-radio submenu, so no
--- edit to voice-dictate-menu.lua is needed when a knob is added.
local MENU_ORDER = {M.SETTING.ENGINE, M.SETTING.SDL2_CAPTURE_ID}

--- Build the checked-radio items for one enum setting. Each item persists its
--- value on click; the checkmark tracks the currently stored value. Extracted
--- so M.buildSettingsMenu's loop body stays thin (one call per setting).
--- @param name string A settings.SETTING.* name.
--- @return table Radio menu item descriptors for one setting.
local function buildChoiceRadio(name)
  local current = M.get(name)
  local radio = {}
  for _, choice in ipairs(M.choices(name) or {}) do
    table.insert(radio, {
      title = M.choiceLabel(name, choice),
      checked = (choice == current),
      fn = function() M.set(name, choice) end,
    })
  end
  return radio
end

--- True iff a setting's row should be shown now — its visible_when predicate
--- passes, or it has none. Lets a row gate on another setting (the SDL2 device
--- only applies to the whisper engine) without engine logic in the menu module.
--- @param name string A settings.SETTING.* name.
--- @return boolean
local function isVisible(name)
  local row = SCHEMA[name]
  if not row or not row.visible_when then return true end
  return row.visible_when()
end

--- Build the "Settings ▸" submenu — one checked-radio submenu per visible enum
--- setting in MENU_ORDER. Built fresh each time the parent dropdown opens (the
--- menubar registers its menu as a callback), so checkmarks and row visibility
--- reflect the stored values on every open. Mirrors voice-dictate-mic.buildMicMenu().
--- @return table Nested submenu descriptors for hs.menubar.
function M.buildSettingsMenu()
  local items = {}
  for _, name in ipairs(MENU_ORDER) do
    if isVisible(name) then
      table.insert(items, {title = M.label(name), menu = buildChoiceRadio(name)})
    end
  end
  return items
end

return M
