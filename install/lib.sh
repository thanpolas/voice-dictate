#!/usr/bin/env bash
# @fileoverview Shared helpers sourced by every other install/ script. Owns
# interactive y/N prompts, free-form prompts with defaults, prefixed log
# output, and required-command checks. No module-level state; safe to source
# multiple times.

set -euo pipefail

# ANSI colour escapes used by log() to keep level prefixes scannable.
# Defined as readonly so duplicate sourcing (when several helpers source
# lib.sh in one orchestrator run) does not error on redeclaration.
if [[ -z "${DK_LIB_COLORS_INITIALISED:-}" ]]; then
  readonly DK_COLOR_RESET=$'\033[0m'
  readonly DK_COLOR_INFO=$'\033[1;34m'
  readonly DK_COLOR_WARN=$'\033[1;33m'
  readonly DK_COLOR_ERROR=$'\033[1;31m'
  readonly DK_COLOR_OK=$'\033[1;32m'
  readonly DK_LIB_COLORS_INITIALISED=1
fi

# Prompt the user with a free-form question and a default; echo the chosen value.
# Uses read -p which writes the prompt to stderr, so this function is safe to
# capture via $(ask …).
# $1 — prompt text shown to the user.
# $2 — default returned when the user presses Enter alone.
function ask() {
  local prompt="${1}"
  local default="${2}"
  local answer
  read -r -p "${prompt} [${default}]: " answer
  echo "${answer:-${default}}"
}

# Prompt the user with a yes/no question and return 0 for yes, 1 for no.
# $1 — prompt text shown to the user (do not include the [y/N] suffix).
# $2 — default answer, "y" or "n", used when the user presses Enter alone.
function confirm() {
  local prompt="${1}"
  local default="${2:-y}"
  local hint="[Y/n]"
  if [[ "${default}" == "n" ]]; then
    hint="[y/N]"
  fi
  local answer
  read -r -p "${prompt} ${hint} " answer
  answer="${answer:-${default}}"
  case "${answer}" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# Emit a log line to stderr with a coloured level prefix.
# $1 — level token: "info", "warn", "error", or "ok".
# $2… — message body; multiple arguments are joined with spaces.
function log() {
  local level="${1}"
  shift
  local color
  case "${level}" in
    info)  color="${DK_COLOR_INFO}" ;;
    warn)  color="${DK_COLOR_WARN}" ;;
    error) color="${DK_COLOR_ERROR}" ;;
    ok)    color="${DK_COLOR_OK}" ;;
    *)     color="${DK_COLOR_RESET}" ;;
  esac
  printf '%b[%s]%b %s\n' "${color}" "${level}" "${DK_COLOR_RESET}" "$*" >&2
}

# Verify a required command is on PATH; abort with a helpful message if not.
# Used by helpers that need a tool they cannot install themselves (e.g. git,
# curl) and that the host system is expected to already have.
# $1 — command name to check for.
function require_cmd() {
  local cmd="${1}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log error "required command not found on PATH: ${cmd}"
    exit 1
  fi
}
