#!/usr/bin/env bash
# @fileoverview Hammerspoon integration. Symlinks the voice-dictate Lua
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

# Symlink every voice-dictate Lua module into ~/.hammerspoon/.
# Force-overwrites prior symlinks so a repo move on disk fixes itself. All
# modules land in one directory so Lua's require() resolves siblings via
# package.path. Globs the repo's hammerspoon/ dir, so new modules need no
# change here.
# $1 — absolute path to the repo's hammerspoon/ source directory.
# $2 — destination directory (typically ~/.hammerspoon).
function link_modules() {
  local src_dir="${1}"
  local dest_dir="${2}"
  mkdir -p "${dest_dir}"
  local module name
  for module in "${src_dir}"/*.lua; do
    name="$(basename "${module}")"
    ln -sf "${module}" "${dest_dir}/${name}"
    log ok "linked ${dest_dir}/${name} -> ${module}"
  done
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

# Filesystem sentinel written by voice-dictate.lua's M.start() after the
# hotkeys + eventtap are bound. Polled below so the permissions walkthrough
# only opens once macOS has actually registered Hammerspoon's TCC access.
readonly VD_READY_SENTINEL="/tmp/voice-dictate-ready"

# Maximum seconds to wait for the sentinel before falling back; the load is
# typically ~1s on first run, longer on cold start when the app must boot.
readonly VD_READY_TIMEOUT_S=15

# Launch Hammerspoon if it isn't already running, trigger a config reload,
# and block until voice-dictate.lua has finished M.start() — i.e. the
# eventtap and hotkeys are live and macOS has logged them with TCC. Without
# this wait the Input Monitoring pane opens before Hammerspoon attempts the
# event tap, leaving the app missing from the list.
function reload_hammerspoon() {
  rm -f "${VD_READY_SENTINEL}"
  if ! pgrep -x Hammerspoon >/dev/null; then
    log info "launching Hammerspoon"
    open -ga Hammerspoon
  fi
  open -g "hammerspoon://reload"
  log info "requested Hammerspoon reload; waiting for it to come up"
  local waited=0
  while [[ ! -f "${VD_READY_SENTINEL}" && "${waited}" -lt "${VD_READY_TIMEOUT_S}" ]]; do
    sleep 1
    waited=$((waited + 1))
  done
  if [[ ! -f "${VD_READY_SENTINEL}" ]]; then
    log warn "Hammerspoon did not signal ready within ${VD_READY_TIMEOUT_S}s"
    log warn "check the Hammerspoon Console for load errors before proceeding"
    return 0
  fi
  # Brief extra settle so the eventtap registration shows up in the
  # Input Monitoring list when System Settings queries TCC next.
  sleep 1
  log ok "Hammerspoon ready"
}
