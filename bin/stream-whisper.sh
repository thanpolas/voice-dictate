#!/usr/bin/env bash
# @fileoverview EXPERIMENTAL whisper-stream recorder — the opt-in streaming
# engine that captures via SDL2 and emits revisable transcription windows on
# stdout until SIGINT/SIGTERM. Sibling of bin/stream.sh (the stable ffmpeg +
# whisper-server engine); selected only when the menubar Engine choice is set
# to whisper-stream. Consumed by hammerspoon/voice-dictate-stream-whisper.lua.
#
# WHY EXPERIMENTAL: SDL2's CoreAudio path bypasses macOS's Voice Processing IO
# unit (AGC / noise-suppression / echo-cancel). On mics that need that DSP the
# transcript hallucinates — the reason streaming was rebuilt on ffmpeg. This
# script exists for setups where SDL2 capture is acceptable; see
# engineering/plans/2026-05-31-pluggable-streaming-engines.md.
#
# Subcommands:
#   stream [capture-id]   Launch whisper-stream in step mode against SDL2
#                         capture device <capture-id> (default -1 = SDL2
#                         default). Emits raw stdout windows until killed.
#
# Runtime config (MODEL_PATH, LANGUAGE, THREADS) is sourced from the same
# bin/config.local.sh the single-shot path uses. Streaming-specific knobs
# (STREAM_STEP_MS, STREAM_LENGTH_MS, STREAM_KEEP_MS) default locally so existing
# config.local.sh files load without changes. The capture device is passed as
# an argument (from the menubar SDL2 picker), not a config key.
#
# Exit codes: 0 on clean shutdown, 1 on usage / missing config, propagated
# child exit code on whisper-stream failure.

set -euo pipefail

# Hammerspoon-spawned tasks inherit a minimal PATH; ensure Homebrew binaries
# (whisper-stream) are reachable regardless of caller environment.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# ───── local config ──────────────────────────────────────────────────────────

# Absolute path to this script's directory — used to locate the sibling config.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# User-specific runtime config; gitignored, written by install.sh.
readonly LOCAL_CONFIG="${SCRIPT_DIR}/config.local.sh"

if [[ ! -f "${LOCAL_CONFIG}" ]]; then
  echo "stream-whisper: missing ${LOCAL_CONFIG}. Run ./install.sh from the repo root." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${LOCAL_CONFIG}"

# Lock the values shared with the single-shot path. THREADS is reused as-is;
# whisper-stream accepts the same -t flag whisper-cli does.
readonly MODEL_PATH LANGUAGE THREADS

# Audio step size in ms — how often whisper-stream emits the current transcript
# of the rolling window. 500ms is the threshold where revisions feel live
# without thrashing the splice layer; the binary's own default 3000ms is too
# slow for the "text appears while I speak" UX.
: "${STREAM_STEP_MS:=500}"
readonly STREAM_STEP_MS

# Length of the rolling audio window in ms — how much recent audio the model
# reconsiders on each emission. 10s gives whisper enough context to anchor on;
# 5s starved large-v3 of context and produced subtitle-style hallucinations.
: "${STREAM_LENGTH_MS:=10000}"
readonly STREAM_LENGTH_MS

# Audio carried from the previous step in ms — boundary continuity so the
# leading words of a new window aren't re-segmented from a partial syllable.
: "${STREAM_KEEP_MS:=200}"
readonly STREAM_KEEP_MS

# SDL2 default capture device. Passed to whisper-stream's --capture when the
# caller supplies no explicit device id. NOT the same numbering as ffmpeg's
# avfoundation AUDIO_DEVICE — SDL2 orders its own devices independently.
readonly STREAM_DEFAULT_CAPTURE_ID="-1"

# ───── subcommands ────────────────────────────────────────────────────────────

# Launch whisper-stream in step mode; emit raw stdout windows until killed.
# Exec replaces this shell with whisper-stream so SIGTERM from Hammerspoon
# reaches the binary directly — SDL2 capture cleans up on process exit and
# there is no WAV trailer to flush. One process, one consumer, no wrapper.
# $1 — SDL2 capture device id (optional; defaults to STREAM_DEFAULT_CAPTURE_ID).
function stream() {
  local capture_id="${1:-${STREAM_DEFAULT_CAPTURE_ID}}"
  if [[ ! -f "${MODEL_PATH}" ]]; then
    echo "stream-whisper: model not found at ${MODEL_PATH}" >&2
    return 1
  fi
  exec whisper-stream \
    --model "${MODEL_PATH}" \
    --language "${LANGUAGE}" \
    --threads "${THREADS}" \
    --step "${STREAM_STEP_MS}" \
    --length "${STREAM_LENGTH_MS}" \
    --keep "${STREAM_KEEP_MS}" \
    --capture "${capture_id}" \
    --keep-context
}

# ───── entry point ────────────────────────────────────────────────────────────

# Dispatch the first positional argument to the matching subcommand.
function main() {
  local cmd="${1:-stream}"
  case "${cmd}" in
    stream) shift || true; stream "$@" ;;
    *)
      echo "usage: stream-whisper.sh stream [capture-id]" >&2
      exit 1
      ;;
  esac
}

main "$@"
