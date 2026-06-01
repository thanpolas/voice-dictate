#!/usr/bin/env bash
# @fileoverview Dependency detection and installation. Confirms Homebrew is
# present (bootstrapping it on consent when absent) and then prompts per
# missing package before invoking brew install. Owns the Homebrew side of
# the bootstrap only — model file and Hammerspoon wiring live in sibling
# helpers.

set -euo pipefail

# Source lib.sh from the same directory so log() and confirm() are available.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Canonical URL for the official Homebrew installer; used by bootstrap_brew.
readonly DK_BREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

# Check whether the brew command is available on PATH.
# Returns 0 when Homebrew is present, 1 otherwise. Pure detection — no output,
# no prompts, no side effects.
function verify_brew() {
  command -v brew >/dev/null 2>&1
}

# Bootstrap Homebrew via its official installer after explicit consent.
# Exits 1 with a manual-install pointer when the user declines, since every
# other dep flows through brew.
function bootstrap_brew() {
  log warn "Homebrew is not installed."
  echo "Homebrew is the package manager Dikta uses to install ffmpeg," >&2
  echo "whisper-cpp, and Hammerspoon. Installer source: https://brew.sh" >&2
  if ! confirm "Install Homebrew now?" y; then
    log error "Homebrew is required. Install it from https://brew.sh and re-run."
    exit 1
  fi
  /bin/bash -c "$(curl -fsSL "${DK_BREW_INSTALL_URL}")"
  if ! verify_brew; then
    log error "Homebrew installer ran but 'brew' is still not on PATH."
    log error "Open a new shell or follow the installer's post-install hint, then re-run."
    exit 1
  fi
  log ok "Homebrew installed."
}

# Prompt for, and on consent install, a single Homebrew package.
# Skips the prompt cleanly (returns 0) if the user declines, since the caller
# decides whether the dep is fatal-on-skip.
# $1 — package name passed to brew install.
# $2 — type, "formula" or "cask".
# $3 — human-readable description shown in the consent prompt.
function install_dep() {
  local package="${1}"
  local type="${2}"
  local description="${3}"
  log warn "${description} (${package}) is not installed."
  if ! confirm "Install ${package} via brew?" y; then
    log warn "Skipped ${package}. Dikta may not work until it is installed."
    return 0
  fi
  if [[ "${type}" == "cask" ]]; then
    brew install --cask "${package}"
  else
    brew install "${package}"
  fi
  log ok "${package} installed."
}
