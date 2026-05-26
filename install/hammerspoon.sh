#!/usr/bin/env bash
# @fileoverview Hammerspoon integration. Symlinks the two voice-dictate Lua
# modules into ~/.hammerspoon/ so the user's init.lua can require them,
# appends the loader line on first install, and triggers an in-place reload
# via the hammerspoon:// URL scheme so changes take effect without a manual
# restart of the Hammerspoon app.

set -euo pipefail

# Source lib.sh from the same directory so log() is available.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Single line appended to init.lua; matched verbatim to keep patching idempotent.
readonly VD_LOADER_LINE='require("voice-dictate").start()'

# Symlink the voice-dictate Lua modules into ~/.hammerspoon/.
# Force-overwrites any prior symlinks so a repo move on disk fixes itself.
# Both files must land in the same directory so Lua's require() resolves the
# sibling mic-picker module via package.path.
# $1 — absolute path to hammerspoon/voice-dictate.lua in the repo.
# $2 — absolute path to hammerspoon/voice-dictate-mic.lua in the repo.
# $3 — destination directory (typically ~/.hammerspoon).
function link_modules() {
  local src_main="${1}"
  local src_mic="${2}"
  local dest_dir="${3}"
  mkdir -p "${dest_dir}"
  ln -sf "${src_main}" "${dest_dir}/voice-dictate.lua"
  log ok "linked ${dest_dir}/voice-dictate.lua -> ${src_main}"
  ln -sf "${src_mic}" "${dest_dir}/voice-dictate-mic.lua"
  log ok "linked ${dest_dir}/voice-dictate-mic.lua -> ${src_mic}"
}

# Append the require("voice-dictate").start() line to init.lua if absent.
# Creates the file if it doesn't exist yet. A verbatim grep keeps re-runs idempotent.
# $1 — absolute path to the user's ~/.hammerspoon/init.lua.
function patch_init_lua() {
  local init_lua="${1}"
  if [[ -f "${init_lua}" ]] && grep -Fq "${VD_LOADER_LINE}" "${init_lua}"; then
    log info "init.lua already requires voice-dictate — skipping patch"
    return 0
  fi
  printf '\n-- voice-dictate (installed by voice-dictate/install.sh)\n%s\n' \
    "${VD_LOADER_LINE}" >> "${init_lua}"
  log ok "patched ${init_lua}"
}

# Trigger Hammerspoon to reload its config without restarting the app.
# Uses the hammerspoon:// URL scheme so this works even when Hammerspoon is
# already running in the background.
function reload_hammerspoon() {
  open -g "hammerspoon://reload"
  log info "requested Hammerspoon reload"
}
