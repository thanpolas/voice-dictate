--- @fileoverview Mic picker — enumerate avfoundation audio inputs, persist
--- the user's choice, build the menubar dropdown.
---
--- Required by voice-dictate.lua. Selection is stored in NSUserDefaults
--- (hs.settings) so it survives reloads and reboots. The scan runs on every
--- menubar open so plug/unplug of USB or Bluetooth devices is reflected live.
---
--- Public API:
---   M.loadAudioDevice()  Return the active avfoundation index, e.g. ":2".
---   M.buildMicMenu()     Build menu items for hs.menubar:setMenu().

local M = {}

-- ───── constants ────────────────────────────────────────────────────────────

--- avfoundation index used when the user has not yet picked a mic. `:0` is
--- whatever macOS reports as the default audio input — often a virtual device,
--- which is why the user is expected to pick explicitly via the menubar.
local DEFAULT_AUDIO_DEVICE = ":0"

--- hs.settings key holding the user's last-selected avfoundation device index
--- (e.g. ":2"). NSUserDefaults-backed — survives reloads and reboots.
local SETTINGS_KEY_AUDIO_DEVICE = "voice-dictate.audioDevice"

--- Absolute path to ffmpeg used by the device scanner. Hardcoded to the Homebrew
--- prefix because hs.execute inherits Hammerspoon's minimal PATH on launchd.
local FFMPEG_BIN = "/opt/homebrew/bin/ffmpeg"

--- Shell command that lists avfoundation devices. ffmpeg exits non-zero because
--- no input file is supplied; the device list is on stderr, so we redirect 2>&1.
local FFMPEG_LIST_DEVICES_CMD =
  FFMPEG_BIN .. " -hide_banner -f avfoundation -list_devices true -i '' 2>&1"

-- ───── persistence ──────────────────────────────────────────────────────────

--- Load the user's last-selected avfoundation device index, or the default.
--- @return string A string like ":2" suitable for `ffmpeg -i`.
function M.loadAudioDevice()
  return hs.settings.get(SETTINGS_KEY_AUDIO_DEVICE) or DEFAULT_AUDIO_DEVICE
end

--- Persist the user's chosen avfoundation device index to NSUserDefaults.
--- @param index string A string like ":2".
local function saveAudioDevice(index)
  hs.settings.set(SETTINGS_KEY_AUDIO_DEVICE, index)
end

-- ───── scan ─────────────────────────────────────────────────────────────────

--- Run ffmpeg to enumerate avfoundation audio inputs.
--- Synchronous (~0.5s); called by the menubar callback on every menu open so the
--- list reflects current plug/unplug state of USB and Bluetooth devices.
--- @return table List of {index=":N", name="Device Name"} entries, possibly empty.
local function scanAudioDevices()
  local out = hs.execute(FFMPEG_LIST_DEVICES_CMD, false) or ""
  local devices = {}
  local inAudioSection = false
  for line in out:gmatch("[^\n]+") do
    if line:match("AVFoundation audio devices:") then
      inAudioSection = true
    elseif inAudioSection then
      if not line:match("AVFoundation indev @") then break end
      local idx, name = line:match("%]%s*%[(%d+)%]%s+(.+)$")
      if idx and name then
        table.insert(devices, {index = ":" .. idx, name = name})
      end
    end
  end
  return devices
end

-- ───── menu ─────────────────────────────────────────────────────────────────

--- Build the menubar dropdown contents. Called on every menu open by Hammerspoon.
--- @return table Menu item descriptors per hs.menubar:setMenu().
function M.buildMicMenu()
  local devices = scanAudioDevices()
  local selected = M.loadAudioDevice()
  local menu = {{title = "Microphone", disabled = true}}
  if #devices == 0 then
    table.insert(menu, {title = "  no audio devices found", disabled = true})
    return menu
  end
  for _, dev in ipairs(devices) do
    table.insert(menu, {
      title = "  " .. dev.name,
      checked = (dev.index == selected),
      fn = function() saveAudioDevice(dev.index) end,
    })
  end
  return menu
end

return M
