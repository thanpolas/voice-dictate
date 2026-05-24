#!/usr/bin/env bash
# @fileoverview Regression test: dictate.sh transcribe output must be free of
# ANSI escape sequences and other control characters, both directly and when
# invoked the way Hammerspoon does (`/bin/bash -c "..."`, matching the
# `hs.execute(cmd, false)` invocation).
#
# Caught here: the "(B[m" prefix that leaked into pasted transcripts because
# whisper-cli emits `\e(B\e[m` (charset reset + SGR reset), or because a shell
# init file printed something. This test fails if either layer regresses.
#
# Usage:
#   ./bin/test-transcribe-output.sh                  # all scenarios
#   ./bin/test-transcribe-output.sh direct           # one scenario by name
#   ./bin/test-transcribe-output.sh via-bash-c
#
# Exit codes: 0 = all pass, 1 = any failure, 2 = missing prerequisite.

set -euo pipefail

# ───── config ───────────────────────────────────────────────────────────────

readonly REPO_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DICTATE_SH="${REPO_BIN}/dictate.sh"
readonly FIXTURE="/opt/homebrew/share/whisper-cpp/jfk.wav"

# ───── helpers ──────────────────────────────────────────────────────────────

declare -i PASS=0
declare -i FAIL=0
SCENARIO=""

function say()  { echo "[${SCENARIO}] ${*}"; }
function pass() { say "PASS: ${*}"; PASS+=1; }
function fail() { say "FAIL: ${*}"; FAIL+=1; }

# Print every offending byte as hex; returns 0 if none, 1 if any.
# We refuse ALL ESC bytes (0x1B) — there's no legitimate reason for a transcript
# of human speech to contain a terminal control sequence.
function assert_no_esc() {
  local label="${1}"
  local data="${2}"
  if [[ "${data}" == *$'\x1b'* ]]; then
    local hex
    hex="$(printf '%s' "${data}" | head -c 40 | xxd -p | tr -d '\n')"
    fail "${label}: ESC byte found in output (first 40 hex bytes: ${hex})"
    return 1
  fi
  pass "${label}: no ESC bytes"
  return 0
}

# Same idea for any C0 control character except newline (\n=0x0A) and tab (\x09).
function assert_no_other_controls() {
  local label="${1}"
  local data="${2}"
  # Strip allowed controls, see if any other control bytes remain.
  local stripped
  stripped="$(printf '%s' "${data}" | LC_ALL=C tr -d '\n\t')"
  if printf '%s' "${stripped}" | LC_ALL=C grep -q $'[\x01-\x08\x0b-\x1f\x7f]'; then
    fail "${label}: control byte(s) in output"
    return 1
  fi
  pass "${label}: no stray control bytes"
  return 0
}

function summary_and_exit() {
  echo
  echo "===== suite =====  PASS=${PASS}  FAIL=${FAIL}"
  exit $(( FAIL > 0 ? 1 : 0 ))
}
trap summary_and_exit EXIT

# ───── scenarios ────────────────────────────────────────────────────────────

# Invoke dictate.sh transcribe directly (same shell as the caller). Catches
# any ANSI sequence leaking through dictate.sh's own pipeline (the perl
# ANSI-strip step in transcribe()).
function scenario_direct() {
  SCENARIO="direct"
  say "running: LANGUAGE=en ${DICTATE_SH} transcribe ${FIXTURE}"
  local out
  out="$(LANGUAGE=en "${DICTATE_SH}" transcribe "${FIXTURE}")"
  assert_no_esc "direct" "${out}" || return
  assert_no_other_controls "direct" "${out}" || return
}

# Invoke via /bin/bash -c, the exact form hs.execute(cmd, false) uses. This
# catches anything a non-login bash might inject (BASH_ENV, etc.).
function scenario_via_bash_c() {
  SCENARIO="via-bash-c"
  say "running via /bin/bash -c (mimics hs.execute false)"
  local out
  out="$(/bin/bash -c "LANGUAGE=en '${DICTATE_SH}' transcribe '${FIXTURE}'")"
  assert_no_esc "via-bash-c" "${out}" || return
  assert_no_other_controls "via-bash-c" "${out}" || return
}

# Invoke via /bin/bash -l -c, the form hs.execute(cmd, true) uses. We don't
# currently use this code path, but we keep the test so that if someone flips
# the flag back, the failure is loud and immediate.
function scenario_via_login_shell() {
  SCENARIO="via-login-shell"
  say "running via /bin/bash -l -c (mimics hs.execute true)"
  local out
  out="$(/bin/bash -l -c "LANGUAGE=en '${DICTATE_SH}' transcribe '${FIXTURE}'")"
  assert_no_esc "via-login-shell" "${out}" || return
  assert_no_other_controls "via-login-shell" "${out}" || return
}

# Make sure the transcript at least contains a recognisable word from the
# fixture — so we catch the failure mode where we "cleaned" the output by
# returning nothing.
function scenario_non_empty_useful() {
  SCENARIO="non-empty"
  local out
  out="$(LANGUAGE=en "${DICTATE_SH}" transcribe "${FIXTURE}")"
  if [[ -z "${out// /}" ]]; then
    fail "transcript is empty"
    return
  fi
  if ! echo "${out}" | grep -qi 'fellow\|americans\|country'; then
    fail "transcript doesn't contain any expected JFK keywords"
    return
  fi
  pass "transcript non-empty and contains expected content"
}

# ───── runner ───────────────────────────────────────────────────────────────

function require_prereqs() {
  local missing=0
  command -v whisper-cli >/dev/null || { echo "missing: whisper-cli" >&2; missing=1; }
  command -v xxd >/dev/null         || { echo "missing: xxd" >&2; missing=1; }
  [[ -x "${DICTATE_SH}" ]] || { echo "missing executable ${DICTATE_SH}" >&2; missing=1; }
  [[ -f "${FIXTURE}"    ]] || { echo "missing fixture ${FIXTURE}" >&2; missing=1; }
  if (( missing )); then exit 2; fi
}

function main() {
  require_prereqs
  local pick="${1:-all}"
  case "${pick}" in
    all)
      scenario_direct
      scenario_via_bash_c
      scenario_via_login_shell
      scenario_non_empty_useful
      ;;
    direct)           scenario_direct ;;
    via-bash-c)       scenario_via_bash_c ;;
    via-login-shell)  scenario_via_login_shell ;;
    non-empty)        scenario_non_empty_useful ;;
    *)
      echo "usage: $(basename "${0}") [direct|via-bash-c|via-login-shell|non-empty|all]" >&2
      exit 1
      ;;
  esac
}

main "$@"
