#!/usr/bin/env bash
# @fileoverview Configuration file writers. Generates the shell-side runtime
# config (bin/config.local.sh) and the Lua-side hotkey/path config
# (~/.hammerspoon/voice-dictate-config.lua) from prompted and derived values.
# Uses the env-var override default pattern so pre-set values still win.

set -euo pipefail

# Write bin/config.local.sh with the runtime values dictate.sh sources.
# Each entry uses the : "${VAR:=…}" default pattern to respect pre-set env vars.
function write_shell_config() {
  echo "todo: write_shell_config" >&2
  exit 1
}

# Write ~/.hammerspoon/voice-dictate-config.lua with hotkey and path fields.
function write_lua_config() {
  echo "todo: write_lua_config" >&2
  exit 1
}
