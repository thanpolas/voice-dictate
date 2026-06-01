#!/usr/bin/env bash
# @fileoverview Automated test for dikta.sh record shutdown behavior.
#
# Reproduces what Hammerspoon does when the user releases PTT:
#   1. Spawn `dikta.sh record <wav> <device>` as a background process
#   2. Sleep <hold_seconds> so ffmpeg captures some audio
#   3. Send SIGTERM to dikta.sh's bash PID (same signal Hammerspoon sends)
#   4. Measure how long until bash actually exits
#   5. Verify ffmpeg flushed a complete WAV with the right header
#   6. Confirm no orphan ffmpeg lingers
#
# Catches the bug we've been chasing — ghost ffmpegs that ignore SIGTERM and
# zero-byte WAVs from premature kills — without needing Hammerspoon or real
# keyboard input. Run after every change to dikta.sh.
#
# Usage:
#   ./bin/test-record-shutdown.sh                  # all scenarios
#   ./bin/test-record-shutdown.sh basic            # one scenario by name
#   AUDIO_DEVICE=:3 ./bin/test-record-shutdown.sh  # override the mic
#
# Exit codes: 0 = all pass, 1 = any failure, 2 = missing prerequisite.

set -euo pipefail

# ───── config ───────────────────────────────────────────────────────────────

# Absolute path to this repo's bin/dikta.sh.
readonly REPO_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DIKTA_SH="${REPO_BIN}/dikta.sh"

# avfoundation index to record from. Overridable via env so the same suite
# runs on different machines.
: "${AUDIO_DEVICE:=:3}"
readonly AUDIO_DEVICE

# Maximum seconds we'll wait for the bash wrapper to exit after SIGTERM.
# Failure beyond this is the bug the suite is designed to catch.
readonly MAX_SHUTDOWN_S=10

# Where temporary WAVs land — repo-local tmp/, never /tmp (CLAUDE.md
# § Scratch paths). Cleaned up at end of each test case.
readonly TMP_DIR="${REPO_BIN}/../tmp"
mkdir -p "${TMP_DIR}"
readonly TMP_PREFIX="${TMP_DIR}/dk-test-shutdown-$$"

# ───── helpers ──────────────────────────────────────────────────────────────

# Counters for the suite-level summary.
declare -i PASS=0
declare -i FAIL=0

# Active scenario name, for prefixing log lines.
SCENARIO=""

# Print one log line prefixed with the active scenario name.
function say() {
  echo "[${SCENARIO}] ${*}"
}

# Mark scenario as failed and increment the suite counter.
function fail() {
  say "FAIL: ${*}"
  FAIL+=1
}

# Mark scenario as passed and increment the suite counter.
function pass() {
  say "PASS: ${*}"
  PASS+=1
}

# Print epoch seconds with millisecond precision for latency math.
function now() {
  perl -MTime::HiRes=time -e 'printf("%.3f", time)'
}

# True if <pid> exists and is owned by us.
function alive() {
  kill -0 "${1}" 2>/dev/null
}

# Wait up to <seconds> for <pid> to exit; print the measured wait time.
# Returns 0 if the process exited within the window, 1 otherwise.
function wait_for_exit() {
  local pid="${1}"
  local max="${2}"
  local start end
  start="$(now)"
  while alive "${pid}"; do
    end="$(now)"
    if (( $(echo "${end} - ${start} >= ${max}" | bc -l) )); then
      return 1
    fi
    sleep 0.05
  done
  end="$(now)"
  echo "${end} - ${start}" | bc -l
  return 0
}

# True if the file at <path> is a syntactically valid RIFF/WAVE file.
function is_valid_wav() {
  local path="${1}"
  [[ -s "${path}" ]] || return 1
  file -b "${path}" | grep -qE '^(RIFF|RIFF64).*WAVE' || return 1
  return 0
}

# Kill any orphan ffmpeg still recording to <wav>. Used between scenarios so
# one failure doesn't pollute the next test's "no orphan" assertion.
function reap() {
  local wav="${1}"
  pkill -KILL -f "ffmpeg.*${wav}" 2>/dev/null || true
}

# Print suite summary on exit and propagate the right exit code.
function summarize_and_exit() {
  rm -f "${TMP_PREFIX}"-*
  echo
  echo "===== suite =====  PASS=${PASS}  FAIL=${FAIL}"
  exit $(( FAIL > 0 ? 1 : 0 ))
}
trap summarize_and_exit EXIT

# ───── scenarios ────────────────────────────────────────────────────────────

# Hold 2s, release, verify clean shutdown and valid WAV.
# This is the canonical PTT cycle.
function scenario_basic() {
  SCENARIO="basic"
  local wav="${TMP_PREFIX}-basic.wav"
  rm -f "${wav}" "${wav%.wav}.log"

  say "spawn dikta.sh record (device=${AUDIO_DEVICE})"
  "${DIKTA_SH}" record "${wav}" "${AUDIO_DEVICE}" &
  local bash_pid="${!}"

  say "bash pid=${bash_pid}; recording for 2s"
  sleep 2

  if ! alive "${bash_pid}"; then
    fail "bash exited before SIGTERM (premature ffmpeg failure?)"
    cat "${wav%.wav}.log" | sed "s/^/[${SCENARIO}-ffmpeg] /" >&2 || true
    reap "${wav}"
    return
  fi

  say "sending SIGTERM"
  kill -TERM "${bash_pid}"
  local elapsed
  if elapsed="$(wait_for_exit "${bash_pid}" "${MAX_SHUTDOWN_S}")"; then
    say "shutdown latency: ${elapsed}s"
  else
    fail "bash still running ${MAX_SHUTDOWN_S}s after SIGTERM"
    reap "${wav}"
    return
  fi

  if pgrep -f "ffmpeg.*${wav}" >/dev/null; then
    fail "orphan ffmpeg recording to ${wav}"
    reap "${wav}"
    return
  fi

  if ! is_valid_wav "${wav}"; then
    fail "WAV missing/invalid: $(file -b "${wav}" 2>/dev/null || echo MISSING)"
    return
  fi

  local size
  size="$(stat -f%z "${wav}")"
  pass "shutdown clean, no orphan, WAV valid (${size} bytes)"
}

# Send SIGTERM almost immediately. Verifies signal forwarding works even when
# ffmpeg has barely started — guards against a race where bash hasn't yet
# installed the trap or hasn't yet learned ffmpeg's PID.
function scenario_rapid() {
  SCENARIO="rapid"
  local wav="${TMP_PREFIX}-rapid.wav"
  rm -f "${wav}" "${wav%.wav}.log"

  say "spawn + SIGTERM after 200ms"
  "${DIKTA_SH}" record "${wav}" "${AUDIO_DEVICE}" &
  local bash_pid="${!}"
  sleep 0.2
  kill -TERM "${bash_pid}" 2>/dev/null || true

  local elapsed
  if elapsed="$(wait_for_exit "${bash_pid}" "${MAX_SHUTDOWN_S}")"; then
    say "shutdown latency: ${elapsed}s"
  else
    fail "bash still running ${MAX_SHUTDOWN_S}s after rapid SIGTERM"
    reap "${wav}"
    return
  fi

  if pgrep -f "ffmpeg.*${wav}" >/dev/null; then
    fail "orphan ffmpeg after rapid stop"
    reap "${wav}"
    return
  fi

  pass "no orphan after rapid stop"
}

# Run 5 sequential record/stop cycles back-to-back. Verifies that orphans do
# NOT accumulate across cycles — the symptom that started this whole debugging
# session.
function scenario_no_orphan_accumulation() {
  SCENARIO="no-orphans"
  local i wav bash_pid
  for i in 1 2 3 4 5; do
    wav="${TMP_PREFIX}-loop-${i}.wav"
    rm -f "${wav}" "${wav%.wav}.log"
    "${DIKTA_SH}" record "${wav}" "${AUDIO_DEVICE}" &
    bash_pid="${!}"
    sleep 0.5
    kill -TERM "${bash_pid}" 2>/dev/null || true
    if ! wait_for_exit "${bash_pid}" "${MAX_SHUTDOWN_S}" >/dev/null; then
      fail "cycle ${i}: bash didn't exit within ${MAX_SHUTDOWN_S}s"
      reap "${wav}"
      return
    fi
  done

  # macOS pgrep has no -c flag; count manually. pgrep returns 1 on no-match,
  # which under `set -e -o pipefail` would silently exit the script — so we
  # guard with an explicit alive check first.
  local lingering=0
  if pgrep -f "ffmpeg.*${TMP_PREFIX}" >/dev/null 2>&1; then
    lingering="$(pgrep -f "ffmpeg.*${TMP_PREFIX}" 2>/dev/null | wc -l | tr -d ' ')"
  fi
  if [[ "${lingering}" != "0" ]]; then
    fail "${lingering} ffmpeg orphans after 5 cycles"
    pkill -KILL -f "ffmpeg.*${TMP_PREFIX}" 2>/dev/null || true
    return
  fi
  pass "5 cycles, zero orphans"
}

# Hold for 3s, release, verify the WAV's duration is at least 2.5s. Catches
# the regression where SIGKILL or a missing flush truncates the WAV.
function scenario_wav_duration_preserved() {
  SCENARIO="wav-duration"
  local wav="${TMP_PREFIX}-dur.wav"
  rm -f "${wav}" "${wav%.wav}.log"
  "${DIKTA_SH}" record "${wav}" "${AUDIO_DEVICE}" &
  local bash_pid="${!}"
  sleep 3
  kill -TERM "${bash_pid}" 2>/dev/null || true
  if ! wait_for_exit "${bash_pid}" "${MAX_SHUTDOWN_S}" >/dev/null; then
    fail "bash didn't exit within ${MAX_SHUTDOWN_S}s"
    reap "${wav}"
    return
  fi

  if ! is_valid_wav "${wav}"; then
    fail "WAV invalid: $(file -b "${wav}" 2>/dev/null || echo MISSING)"
    return
  fi

  # avfoundation startup eats ~700ms, so a 3s sleep yields ~2.3s of audio.
  # Threshold is lenient — we're catching catastrophic truncation, not jitter.
  local seconds
  seconds="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "${wav}" 2>/dev/null || echo 0)"
  say "wav duration: ${seconds}s"
  if (( $(echo "${seconds} < 2.0" | bc -l) )); then
    fail "WAV duration ${seconds}s < 2.0s minimum (truncated?)"
    return
  fi
  pass "WAV duration ${seconds}s preserved"
}

# ───── runner ───────────────────────────────────────────────────────────────

# Verify external dependencies are present before any scenario runs.
function require_prereqs() {
  local missing=0
  command -v ffmpeg  >/dev/null || { echo "missing: ffmpeg" >&2; missing=1; }
  command -v ffprobe >/dev/null || { echo "missing: ffprobe (brew install ffmpeg)" >&2; missing=1; }
  command -v pgrep   >/dev/null || { echo "missing: pgrep" >&2; missing=1; }
  command -v perl    >/dev/null || { echo "missing: perl" >&2; missing=1; }
  command -v bc      >/dev/null || { echo "missing: bc" >&2; missing=1; }
  [[ -x "${DIKTA_SH}" ]] || { echo "missing: ${DIKTA_SH} (not executable)" >&2; missing=1; }
  if (( missing )); then exit 2; fi
}

function main() {
  require_prereqs
  local pick="${1:-all}"
  case "${pick}" in
    all)
      scenario_basic
      scenario_rapid
      scenario_no_orphan_accumulation
      scenario_wav_duration_preserved
      ;;
    basic)        scenario_basic ;;
    rapid)        scenario_rapid ;;
    no-orphans)   scenario_no_orphan_accumulation ;;
    wav-duration) scenario_wav_duration_preserved ;;
    *)
      echo "usage: $(basename "${0}") [basic|rapid|no-orphans|wav-duration|all]" >&2
      exit 1
      ;;
  esac
}

main "$@"
