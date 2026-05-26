#!/usr/bin/env bash
# @fileoverview Dependency detection and installation. Confirms Homebrew is
# present (bootstrapping it on consent when absent) and then prompts per
# missing formula before invoking brew install. Owns the Homebrew side of
# the bootstrap only; does not touch model files or Hammerspoon state.

set -euo pipefail

# Check whether the brew command is available on PATH.
# Returns 0 when Homebrew is present, non-zero otherwise.
function verify_brew() {
  echo "todo: verify_brew" >&2
  exit 1
}

# Bootstrap Homebrew by invoking the upstream installer after explicit consent.
# Exits cleanly with guidance for manual install if the user declines.
function bootstrap_brew() {
  echo "todo: bootstrap_brew" >&2
  exit 1
}

# Prompt for, and on consent install, a single Homebrew formula.
# $1 — formula name passed to brew install.
# $2 — human-readable description shown in the consent prompt.
function install_dep() {
  echo "todo: install_dep" >&2
  exit 1
}
