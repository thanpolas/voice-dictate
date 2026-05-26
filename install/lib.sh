#!/usr/bin/env bash
# @fileoverview Shared helpers sourced by every other install/ script.
# Owns interactive y/N prompts, prefixed log output, and required-command
# checks. No module-level state; stub bodies only at this stage.

set -euo pipefail

# Prompt the user with a yes/no question and echo "y" or "n" to stdout.
# $1 — prompt text shown to the user.
# $2 — default answer ("y" or "n") used when the user presses Enter alone.
function ask() {
  echo "todo: ask" >&2
  exit 1
}

# Emit a log line to stderr with a consistent level prefix.
# $1 — log level token: "info", "warn", or "error".
# $2 — message body.
function log() {
  echo "todo: log" >&2
  exit 1
}

# Verify a required command is on PATH; abort with a helpful message if not.
# $1 — command name to check for.
function require_cmd() {
  echo "todo: require_cmd" >&2
  exit 1
}
