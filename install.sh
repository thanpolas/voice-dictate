#!/usr/bin/env bash
# @fileoverview Idempotent installer for voice-dictate. Verifies dependencies,
# symlinks the Lua module into ~/.hammerspoon, patches init.lua, reloads.
#
# Run from anywhere: `./install.sh` (uses BASH_SOURCE to resolve repo paths).

set -euo pipefail

# ───── paths ────────────────────────────────────────────────────────────────

# Absolute path to this repo's root, derived from the script location.
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source Lua module shipped by this repo.
readonly SRC_LUA="${REPO_ROOT}/hammerspoon/voice-dictate.lua"

# Destination symlink inside the user's Hammerspoon config directory.
readonly DST_LUA="${HOME}/.hammerspoon/voice-dictate.lua"

# User's Hammerspoon entry point — patched to require the voice-dictate module.
readonly INIT_LUA="${HOME}/.hammerspoon/init.lua"

# Single line appended to init.lua; checked verbatim to keep the patch idempotent.
readonly LOADER_LINE='require("voice-dictate").start()'

# Default model path — only checked for existence; not modified by the installer.
readonly MODEL_PATH="${HOME}/whisper-models/ggml-large-v3-turbo-q5_0.bin"

# ───── steps ────────────────────────────────────────────────────────────────

# Abort with message on stderr if a required command is missing.
function require_cmd() {
  local cmd="${1}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "install: missing required command: ${cmd}" >&2
    exit 1
  fi
}

# Verify every external dependency before mutating anything on disk.
function verify_deps() {
  require_cmd ffmpeg
  require_cmd whisper-cli
  if [[ ! -d "/Applications/Hammerspoon.app" ]]; then
    echo "install: Hammerspoon.app not found in /Applications" >&2
    exit 1
  fi
  if [[ ! -f "${MODEL_PATH}" ]]; then
    echo "install: whisper model not found at ${MODEL_PATH}" >&2
    exit 1
  fi
}

# Symlink the Lua module into ~/.hammerspoon, overwriting any prior link.
function link_module() {
  mkdir -p "${HOME}/.hammerspoon"
  ln -sf "${SRC_LUA}" "${DST_LUA}"
  echo "install: linked ${DST_LUA} -> ${SRC_LUA}"
}

# Append the loader line to init.lua if it isn't already present.
function patch_init_lua() {
  if [[ -f "${INIT_LUA}" ]] && grep -Fq "${LOADER_LINE}" "${INIT_LUA}"; then
    echo "install: init.lua already requires voice-dictate — skipping patch"
    return 0
  fi
  printf '\n-- voice-dictate (installed by voice-dictate/install.sh)\n%s\n' \
    "${LOADER_LINE}" >> "${INIT_LUA}"
  echo "install: patched ${INIT_LUA}"
}

# Trigger Hammerspoon to reload its config without restarting the app.
function reload_hammerspoon() {
  open -g "hammerspoon://reload"
  echo "install: requested Hammerspoon reload"
}

function main() {
  verify_deps
  link_module
  patch_init_lua
  reload_hammerspoon
  echo "install: done. Grant Accessibility + Microphone to Hammerspoon if prompted."
}

main "$@"
