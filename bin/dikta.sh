#!/usr/bin/env bash
# @fileoverview Dikta shell entry point — record, transcribe, smoke-test.
#
# Subcommands:
#   record <wav-path>      Capture default mic to WAV until SIGINT (Hammerspoon owns it).
#   transcribe <wav-path>  Run whisper-cli; print plain transcript to stdout.
#   smoke                  Transcribe bundled JFK fixture; assert non-empty output.
#
# Owns the single-shot record-then-transcribe pipeline. The opt-in streaming
# pipeline lives in the sibling bin/stream.sh — different process model,
# different lifecycle, different paste mechanic. Neither modifies the other.
#
# Runtime config (MODEL_PATH, LANGUAGE, THREADS, AUDIO_DEVICE) is sourced from
# the sibling bin/config.local.sh file written by install.sh. Per-invocation
# environment overrides still work (e.g. LANGUAGE=en ./bin/dikta.sh smoke).
#
# Exit codes: 0 on success, 1 on usage error or missing config, propagated
# child exit code on ffmpeg / whisper-cli failure.

set -euo pipefail

# Hammerspoon-spawned tasks inherit a minimal PATH; ensure Homebrew binaries
# (ffmpeg, whisper-cli) are reachable regardless of caller environment.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# ───── local config ──────────────────────────────────────────────────────────

# Absolute path to this script's directory — used to locate the sibling config.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# User-specific runtime config; gitignored, written by install.sh.
readonly LOCAL_CONFIG="${SCRIPT_DIR}/config.local.sh"

if [[ ! -f "${LOCAL_CONFIG}" ]]; then
  echo "dikta: missing ${LOCAL_CONFIG}. Run ./install.sh from the repo root." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${LOCAL_CONFIG}"

# Lock the sourced values for the rest of the run; env overrides applied
# before invocation win because config.local.sh uses the `: "${VAR:=…}"` form.
readonly MODEL_PATH LANGUAGE THREADS AUDIO_DEVICE

# Path to whisper.cpp's bundled JFK fixture used by the smoke subcommand.
# Not user-tunable — it is the brew-installed shared fixture.
readonly SMOKE_FIXTURE="/opt/homebrew/share/whisper-cpp/jfk.wav"

# ───── subcommands ────────────────────────────────────────────────────────────

# Record audio from <device> (or the default mic) to <wav-path> until SIGINT.
# ffmpeg writes the WAV trailer and exits 0 on SIGINT, leaving a valid file.
# Passing the device as a positional arg (rather than via env) lets Hammerspoon
# spawn dikta.sh directly — wrapping in /usr/bin/env breaks the TCC chain
# because macOS treats `env` as the responsible process for the child's mic
# access, and `env` has no Privacy & Security entry.
function record() {
  local wav="${1:?usage: dikta.sh record <wav-path> [device]}"
  local device="${2:-${AUDIO_DEVICE}}"
  local log="${wav%.wav}.log"
  echo "dikta: record start wav=${wav} device=${device}" > "${log}"
  # Bash-wrapper signal forwarding. We do NOT exec ffmpeg — bash stays as the
  # parent process so Hammerspoon's SIGTERM hits bash (which is not blocked on
  # avfoundation and processes signals instantly). Bash then forwards SIGINT
  # to ffmpeg, which ffmpeg handles as a graceful quit: flush WAV trailer and
  # exit. SIGKILL on ffmpeg loses all in-memory buffer (no data on disk), so
  # we never let Hammerspoon hard-kill ffmpeg directly.
  # NO -nostdin: with -nostdin under avfoundation, ffmpeg's signal handling
  # blocks for many seconds (signals only checked between avfoundation reads).
  # With stdin connected, signal handling completes in milliseconds.
  # </dev/null is explicit: we don't want ffmpeg to read anything from stdin,
  # we just need stdin to be open so signal handling stays fast.
  ffmpeg -hide_banner -y \
    -f avfoundation -i "${device}" \
    -ar 16000 -ac 1 -acodec pcm_s16le \
    "${wav}" 2>> "${log}" </dev/null &
  local ffmpeg_pid="${!}"
  echo "dikta: ffmpeg pid=${ffmpeg_pid}" >> "${log}"
  trap "kill -INT ${ffmpeg_pid} 2>/dev/null || true" TERM INT
  # bash's `wait` is interrupted by signals and returns even though the child
  # is still running. Loop until ffmpeg is actually gone so we don't leave an
  # orphan with an unflushed WAV.
  while kill -0 "${ffmpeg_pid}" 2>/dev/null; do
    wait "${ffmpeg_pid}" 2>/dev/null || true
  done
  echo "dikta: ffmpeg exited" >> "${log}"
}

# Transcribe <wav-path>; print plain text transcript to stdout.
# Joins segments onto one line and collapses whitespace for paste-friendly output.
function transcribe() {
  local wav="${1:?usage: dikta.sh transcribe <wav-path>}"
  if [[ ! -f "${MODEL_PATH}" ]]; then
    echo "dikta: model not found at ${MODEL_PATH}" >&2
    return 1
  fi
  # whisper-cli prints ANSI escape sequences (\e(B\e[m) at start/end to reset
  # terminal state. Those leak into the paste as the visible literal "(B[m"
  # unless stripped. Perl handles \e literally; BSD sed on macOS does not.
  whisper-cli \
    -m "${MODEL_PATH}" \
    -f "${wav}" \
    -l "${LANGUAGE}" \
    -t "${THREADS}" \
    -nt -np 2>/dev/null \
    | perl -pe 's/\e\[[0-9;]*[a-zA-Z]//g; s/\e\([A-Z]//g' \
    | tr '\n' ' ' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g'
}

# Transcribe the bundled fixture; assert non-empty output. Exit non-zero on failure.
# Runs with whatever LANGUAGE is set; for the English JFK fixture, the caller is
# expected to invoke as `LANGUAGE=en dikta.sh smoke` for a meaningful check.
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
      echo "usage: dikta.sh {record|transcribe|smoke} [args]" >&2
      exit 1
      ;;
  esac
}

main "$@"
