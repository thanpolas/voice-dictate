#!/usr/bin/env bash
# @fileoverview voice-dictate shell entry point — record, transcribe, smoke-test.
#
# Subcommands:
#   record <wav-path>      Capture default mic to WAV until SIGINT (Hammerspoon owns it).
#   transcribe <wav-path>  Run whisper-cli; print plain transcript to stdout.
#   smoke                  Transcribe bundled JFK fixture; assert non-empty output.
#
# Exit codes: 0 on success, 1 on usage error or assertion failure, propagated
# child exit code on ffmpeg / whisper-cli failure.

set -euo pipefail

# Hammerspoon-spawned tasks inherit a minimal PATH; ensure Homebrew binaries
# (ffmpeg, whisper-cli) are reachable regardless of caller environment.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# ───── constants ──────────────────────────────────────────────────────────────
# Each accepts an environment-variable override (e.g. `LANGUAGE=auto dictate.sh ...`)
# and is then locked readonly for the rest of the run.

# Absolute path to the quantized large-v3-turbo Whisper model.
: "${MODEL_PATH:=${HOME}/tiktok/whisper-models/ggml-large-v3-turbo-q5_0.bin}"
readonly MODEL_PATH

# Spoken language passed to whisper-cli (`el` = Greek; `auto` for detection).
: "${LANGUAGE:=el}"
readonly LANGUAGE

# CPU threads for whisper inference; matches user's existing transcribe() helper.
: "${THREADS:=8}"
readonly THREADS

# avfoundation audio input spec — `:0` selects the macOS default microphone (no video).
: "${AUDIO_DEVICE:=:0}"
readonly AUDIO_DEVICE

# Path to whisper.cpp's bundled JFK fixture used by the smoke subcommand.
readonly SMOKE_FIXTURE="/opt/homebrew/share/whisper-cpp/jfk.wav"

# ───── subcommands ────────────────────────────────────────────────────────────

# Record audio from the default microphone to <wav-path> until SIGINT.
# ffmpeg writes the WAV trailer and exits 0 on SIGINT, leaving a valid file.
function record() {
  local wav="${1:?usage: dictate.sh record <wav-path>}"
  exec ffmpeg -hide_banner -loglevel error -nostdin -y \
    -f avfoundation -i "${AUDIO_DEVICE}" \
    -ar 16000 -ac 1 -acodec pcm_s16le \
    "${wav}"
}

# Transcribe <wav-path>; print plain text transcript to stdout.
# Joins segments onto one line and collapses whitespace for paste-friendly output.
function transcribe() {
  local wav="${1:?usage: dictate.sh transcribe <wav-path>}"
  if [[ ! -f "${MODEL_PATH}" ]]; then
    echo "dictate: model not found at ${MODEL_PATH}" >&2
    return 1
  fi
  whisper-cli \
    -m "${MODEL_PATH}" \
    -f "${wav}" \
    -l "${LANGUAGE}" \
    -t "${THREADS}" \
    -nt -np 2>/dev/null \
    | tr '\n' ' ' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g'
}

# Transcribe the bundled fixture; assert non-empty output. Exit non-zero on failure.
# Runs with whatever LANGUAGE is set; for the English JFK fixture, the caller is
# expected to invoke as `LANGUAGE=en dictate.sh smoke` for a meaningful check.
function smoke() {
  if [[ ! -f "${SMOKE_FIXTURE}" ]]; then
    echo "smoke: fixture not found at ${SMOKE_FIXTURE}" >&2
    return 1
  fi
  local out
  out="$(transcribe "${SMOKE_FIXTURE}" || true)"
  if [[ -z "${out// /}" ]]; then
    echo "smoke: transcribe produced empty output" >&2
    return 1
  fi
  echo "smoke: ok — ${out:0:80}..."
}

# ───── entry point ────────────────────────────────────────────────────────────

# Dispatch first positional argument to the matching subcommand.
function main() {
  local cmd="${1:-}"
  case "${cmd}" in
    record)     shift; record "$@" ;;
    transcribe) shift; transcribe "$@" ;;
    smoke)      smoke ;;
    *)
      echo "usage: dictate.sh {record|transcribe|smoke} [args]" >&2
      exit 1
      ;;
  esac
}

main "$@"
