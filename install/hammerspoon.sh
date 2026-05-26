#!/usr/bin/env bash
# @fileoverview Hammerspoon integration. Symlinks the two voice-dictate Lua
# modules into ~/.hammerspoon/, patches the user's init.lua so the module is
# required on launch, and triggers a Hammerspoon reload so changes take
# effect without a manual restart.

set -euo pipefail

# Symlink the voice-dictate Lua modules into ~/.hammerspoon/.
# Replaces stale symlinks left behind by older voice-dictate checkouts.
function link_modules() {
  echo "todo: link_modules" >&2
  exit 1
}

# Append the require("voice-dictate").start() line to the user's init.lua if absent.
function patch_init_lua() {
  echo "todo: patch_init_lua" >&2
  exit 1
}

# Trigger hs.reload() via the hammerspoon:// URL scheme.
function reload_hammerspoon() {
  echo "todo: reload_hammerspoon" >&2
  exit 1
}
