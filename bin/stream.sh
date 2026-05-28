#!/usr/bin/env bash
# @fileoverview voice-dictate streaming entry point — long-lived whisper-stream.
#
# Subcommands:
#   stream    Launch whisper-stream in step mode; emit raw lines on stdout
#             until SIGINT/SIGTERM. Consumed by hammerspoon/voice-dictate-stream.lua.
#
# Sibling of bin/dictate.sh — single-shot record/transcribe is unchanged. This
# script owns the opt-in streaming path: a long-lived whisper-stream process
# emits revisable transcription hypotheses every STREAM_STEP_MS over the most
# recent STREAM_LENGTH_MS of audio. The Lua paste layer splices each emission
# into the focused field via Shift+Cmd+Up / Cmd+X / modify clipboard / Cmd+V.
# See engineering/plans/2026-05-26-streaming-transcription.md for the contract.
#
# Runtime config (MODEL_PATH, LANGUAGE, THREADS) is sourced from the same
# bin/config.local.sh the single-shot path uses. Streaming-specific knobs
# (STREAM_STEP_MS, STREAM_LENGTH_MS, STREAM_KEEP_MS, STREAM_CAPTURE_ID) take
# defaults locally so existing config.local.sh files don't need updating.
#
# Exit codes: 0 on clean shutdown, 1 on usage / missing config, propagated
# child exit code on whisper-stream failure.

set -euo pipefail

# Hammerspoon-spawned tasks inherit a minimal PATH; ensure Homebrew binaries
# (whisper-stream, whisper-cli) are reachable regardless of caller environment.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# ───── local config ──────────────────────────────────────────────────────────

# Absolute path to this script's directory — used to locate the sibling config.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# User-specific runtime config; gitignored, written by install.sh.
readonly LOCAL_CONFIG="${SCRIPT_DIR}/config.local.sh"

if [[ ! -f "${LOCAL_CONFIG}" ]]; then
  echo "stream: missing ${LOCAL_CONFIG}. Run ./install.sh from the repo root." >&2
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
# slow for the "text appears while I speak" UX this plan targets.
: "${STREAM_STEP_MS:=500}"
readonly STREAM_STEP_MS

# Length of the rolling audio window in ms — how much recent audio the model
# reconsiders on each emission. 5s gives whisper meaningful context while
# keeping per-emission inference under a step interval on Apple Silicon.
: "${STREAM_LENGTH_MS:=5000}"
readonly STREAM_LENGTH_MS

# Audio carried from the previous step in ms — boundary continuity so the
# leading words of a new window aren't re-segmented from a partial syllable.
: "${STREAM_KEEP_MS:=200}"
readonly STREAM_KEEP_MS

# SDL2 capture device ID consumed by whisper-stream's --capture flag. NOT the
# same as ffmpeg's avfoundation MIC_INDEX (different libraries, different
# ordering). -1 = SDL2 default; user-facing calibration is documented in
# bin/README.md and engineering/plans/2026-05-26-streaming-spike-log.md.
: "${STREAM_CAPTURE_ID:=-1}"
readonly STREAM_CAPTURE_ID

# ───── subcommands ────────────────────────────────────────────────────────────

# Launch whisper-stream in step mode; emit raw stdout lines until killed.
# Exec replaces this shell with whisper-stream so SIGTERM from Hammerspoon
# reaches the binary directly — there is no avfoundation-style signal latency
# to mediate, SDL2 capture cleans up on process exit, and there is no WAV
# trailer to flush. One process, one consumer, no wrapper.
function stream() {
  if [[ ! -f "${MODEL_PATH}" ]]; then
    echo "stream: model not found at ${MODEL_PATH}" >&2
    return 1
  fi
  exec whisper-stream \
    --model "${MODEL_PATH}" \
    --language "${LANGUAGE}" \
    --threads "${THREADS}" \
    --step "${STREAM_STEP_MS}" \
    --length "${STREAM_LENGTH_MS}" \
    --keep "${STREAM_KEEP_MS}" \
    --capture "${STREAM_CAPTURE_ID}" \
    --keep-context
}

# ───── entry point ────────────────────────────────────────────────────────────

# Dispatch first positional argument to the matching subcommand.
function main() {
  local cmd="${1:-stream}"
  case "${cmd}" in
    stream) shift || true; stream "$@" ;;
    *)
      echo "usage: stream.sh [stream]" >&2
      exit 1
      ;;
  esac
}

main "$@"
