#!/usr/bin/env bash
# @fileoverview voice-dictate streaming capture — continuous ffmpeg recording.
#
# Subcommands:
#   record <wav-path>  Capture mic to WAV until SIGTERM/SIGINT, same flags as
#                      bin/dictate.sh record. Hammerspoon owns the WAV path
#                      and signals shutdown when the session ends.
#
# Sibling of bin/dictate.sh, sharing its AVFoundation capture path so the same
# Voice Processing IO unit (AGC, noise suppression, echo cancellation) runs
# under both single-shot and streaming. Earlier streaming used whisper-stream
# (SDL2), which bypassed that DSP and produced unusable transcripts from the
# iMac internal mic. See engineering/plans/2026-05-28-ffmpeg-streaming-rebuild.md.
#
# Runtime config (LANGUAGE, AUDIO_DEVICE) is sourced from bin/config.local.sh —
# the same file the single-shot path uses, so mic selection is one knob.
#
# Exit codes: 0 on clean shutdown, 1 on usage / missing config, propagated
# child exit code on ffmpeg failure.

set -euo pipefail

# Hammerspoon-spawned tasks inherit a minimal PATH; ensure Homebrew binaries
# (ffmpeg) are reachable regardless of caller environment.
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

# Lock the values shared with the single-shot path.
readonly AUDIO_DEVICE

# ───── subcommands ────────────────────────────────────────────────────────────

# Record audio from the configured AVFoundation device to <wav-path> until
# SIGTERM/SIGINT. Same bash-wrapper-forwards-SIGINT-to-ffmpeg dance as
# dictate.sh's record subcommand — ffmpeg flushes the WAV trailer on SIGINT
# and exits 0, so the file is always playable. Hammerspoon's hs.task is the
# parent and signals via SIGTERM at session end.
function record() {
  local wav="${1:?usage: stream.sh record <wav-path> [device]}"
  local device="${2:-${AUDIO_DEVICE}}"
  local log="${wav%.wav}.log"
  echo "stream: record start wav=${wav} device=${device}" > "${log}"
  # See bin/dictate.sh's record for the full rationale on the bash-wrapper
  # SIGINT forwarding and the explicit </dev/null stdin redirect; this path
  # mirrors that contract so the same end-to-end shutdown tests cover it.
  ffmpeg -hide_banner -y \
    -f avfoundation -i "${device}" \
    -ar 16000 -ac 1 -acodec pcm_s16le \
    "${wav}" 2>> "${log}" </dev/null &
  local ffmpeg_pid="${!}"
  echo "stream: ffmpeg pid=${ffmpeg_pid}" >> "${log}"
  trap "kill -INT ${ffmpeg_pid} 2>/dev/null || true" TERM INT
  while kill -0 "${ffmpeg_pid}" 2>/dev/null; do
    wait "${ffmpeg_pid}" 2>/dev/null || true
  done
  echo "stream: ffmpeg exited" >> "${log}"
}

# ───── entry point ────────────────────────────────────────────────────────────

# Dispatch first positional argument to the matching subcommand.
function main() {
  local cmd="${1:-}"
  case "${cmd}" in
    record) shift; record "$@" ;;
    *)
      echo "usage: stream.sh record <wav-path> [device]" >&2
      exit 1
      ;;
  esac
}

main "$@"
