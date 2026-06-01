#!/usr/bin/env bash
# @fileoverview Idempotent installer for Dikta. Thin orchestrator over
# the install/ helpers — verifies dependencies (prompting to install missing
# ones via Homebrew), resolves a Whisper model (reusing one on disk or
# downloading the default on consent), writes the two runtime config files,
# wires Hammerspoon, and walks the user through the macOS permissions panes.
#
# Subcommands:
#   install (default) — run the full bootstrapper.
#   update            — placeholder; tagged-release update flow lands in a follow-up PR.

set -euo pipefail

# Absolute path to this repo's root, derived from the script location.
# Split declaration from assignment so the cd-subshell exit status is not masked.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT

# Hammerspoon configuration directory in the user's home.
readonly DK_HAMMERSPOON_DIR="${HOME}/.hammerspoon"

# Source directory of Lua modules shipped by this repo; every *.lua here is
# symlinked into the Hammerspoon dir, so new modules need no change here.
readonly DK_SRC_LUA_DIR="${REPO_ROOT}/hammerspoon"

# User's Hammerspoon entry point — patched to require the Dikta module.
readonly DK_INIT_LUA="${DK_HAMMERSPOON_DIR}/init.lua"

# Runtime config files written by the installer; both required by the tool.
readonly DK_SHELL_CONFIG="${REPO_ROOT}/bin/config.local.sh"
readonly DK_LUA_CONFIG="${DK_HAMMERSPOON_DIR}/dikta-config.lua"

# Project-local artifact store; install.sh creates it on first run.
readonly DK_LOCAL_MODELS_DIR="${REPO_ROOT}/.local/models"

# Default language for the Whisper transcription — Greek primary per spec.
# DK_DEFAULT_MODEL_FILENAME is declared in install/model.sh and reaches us
# via the source line below; declaring it here would double-readonly under
# set -e and abort the script.
readonly DK_DEFAULT_LANGUAGE="el"

# Source every helper so their public functions are in scope. lib.sh is
# transitively sourced by each helper; its colour constants are reload-safe.
# shellcheck source=install/deps.sh
source "${REPO_ROOT}/install/deps.sh"
# shellcheck source=install/model.sh
source "${REPO_ROOT}/install/model.sh"
# shellcheck source=install/config.sh
source "${REPO_ROOT}/install/config.sh"
# shellcheck source=install/hammerspoon.sh
source "${REPO_ROOT}/install/hammerspoon.sh"

# Read MODEL_PATH and LANGUAGE from an existing config.local.sh, if any.
# Echoes "model|language" so the orchestrator can split it; empty fields when
# the config does not exist or does not set the value.
function read_existing_config() {
  if [[ ! -f "${DK_SHELL_CONFIG}" ]]; then
    echo "|"
    return 0
  fi
  # shellcheck source=/dev/null
  source "${DK_SHELL_CONFIG}"
  echo "${MODEL_PATH:-}|${LANGUAGE:-}"
}

# Detect a Homebrew package by command name; install it on consent if missing.
# Wraps the install_dep helper with a per-package presence check so the prompt
# only fires when the user actually needs to act.
# $1 — command name to probe for presence.
# $2 — Homebrew package name to install if absent.
# $3 — package type, "formula" or "cask".
# $4 — human-readable description shown in the consent prompt.
function ensure_brew_dep_by_command() {
  if command -v "${1}" >/dev/null 2>&1; then
    return 0
  fi
  install_dep "${2}" "${3}" "${4}"
}

# Run the full install flow. Idempotent — re-runs detect existing state and
# skip work that is already done.
function cmd_install() {
  log info "Dikta installer starting"

  if ! verify_brew; then
    bootstrap_brew
  fi
  ensure_brew_dep_by_command ffmpeg ffmpeg formula "Audio capture (FFmpeg)"
  ensure_brew_dep_by_command whisper-cli whisper-cpp formula "Whisper transcription CLI"
  if [[ ! -d "/Applications/Hammerspoon.app" ]]; then
    install_dep hammerspoon cask "macOS automation framework (Hammerspoon)"
  fi

  local prior model_default language_default
  prior="$(read_existing_config)"
  model_default="${prior%|*}"
  language_default="${prior##*|}"
  : "${model_default:=${DK_LOCAL_MODELS_DIR}/${DK_DEFAULT_MODEL_FILENAME}}"
  : "${language_default:=${DK_DEFAULT_LANGUAGE}}"

  echo
  log info "Dikta config — press Enter to accept defaults"
  local cfg_model cfg_language
  cfg_model="$(ask "Whisper model path" "${model_default}")"
  cfg_language="$(ask "Default language (el, en, auto, …)" "${language_default}")"

  local resolved_model
  resolved_model="$(ensure_model "${cfg_model}" "${DK_LOCAL_MODELS_DIR}/${DK_DEFAULT_MODEL_FILENAME}")"

  # Resolve the ffmpeg binary now so the Lua config carries an absolute path.
  # Hammerspoon launches from launchd with a minimal PATH and cannot look up
  # `ffmpeg` itself; embedding the resolved path here keeps the streaming
  # pipeline portable across Apple Silicon (/opt/homebrew) and Intel
  # (/usr/local) without literals in the Lua module.
  local ffmpeg_path
  ffmpeg_path="$(command -v ffmpeg)"
  if [[ -z "${ffmpeg_path}" ]]; then
    log error "ffmpeg not found on PATH after dependency setup; cannot continue"
    exit 1
  fi

  write_shell_config "${DK_SHELL_CONFIG}" "${resolved_model}" "${cfg_language}"
  write_lua_config "${DK_LUA_CONFIG}" "${REPO_ROOT}/bin/dikta.sh" "${ffmpeg_path}"
  link_modules "${DK_SRC_LUA_DIR}" "${DK_HAMMERSPOON_DIR}"
  patch_init_lua "${DK_INIT_LUA}"
  reload_hammerspoon

  echo
  log ok "Dikta installed. Hotkeys: Right Option (PTT), Cmd+Shift+D (toggle)"
  log info "macOS will prompt for Accessibility, Input Monitoring, and Microphone on first use — grant each when asked."
}

# Placeholder for the tagged-release update flow; real logic lands in the
# follow-up PR per D7 of the install UX bootstrap plan.
function cmd_update() {
  log warn "'update' is not yet implemented — coming in a follow-up release."
  log warn "For now: git pull && ./install.sh re-runs the bootstrapper idempotently."
  exit 0
}

# Dispatch subcommand. Default is 'install' when no argument is given.
function main() {
  local subcommand="${1:-install}"
  case "${subcommand}" in
    install) cmd_install ;;
    update)  cmd_update ;;
    *) log error "unknown subcommand: ${subcommand}"; exit 1 ;;
  esac
}

main "$@"
