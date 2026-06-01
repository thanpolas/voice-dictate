#!/usr/bin/env bash
# @fileoverview Dikta streaming inference daemon — whisper-server lifecycle.
#
# Subcommands:
#   start [port]   Spawn whisper-server on loopback with the configured model
#                  and language. Idempotent: re-runs while the daemon is alive
#                  exit 0. Writes the PID and log to the repo-local tmp/ dir
#                  (project rule: never /tmp; see CLAUDE.md § Scratch paths).
#   stop           Kill the daemon if a PID file exists. Safe to repeat.
#   status         Echo "running PID" or "stopped"; exit 0 / 1 accordingly.
#
# Why a daemon: each whisper-cli invocation pays ~500ms-1s to load the model.
# whisper-server loads once and serves transcription requests over HTTP — the
# repeated-inference cost of step-3's timer loop becomes inference-only.
#
# Runtime config (MODEL_PATH, LANGUAGE, THREADS) is sourced from
# bin/config.local.sh — the same file the single-shot path uses.

set -euo pipefail

# Hammerspoon-spawned tasks inherit a minimal PATH; ensure Homebrew binaries
# are reachable regardless of caller environment.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

# ───── local config ──────────────────────────────────────────────────────────

# Absolute path to this script's directory — used to locate the sibling config.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# User-specific runtime config; gitignored, written by install.sh.
readonly LOCAL_CONFIG="${SCRIPT_DIR}/config.local.sh"

if [[ ! -f "${LOCAL_CONFIG}" ]]; then
  echo "stream-server: missing ${LOCAL_CONFIG}. Run ./install.sh from the repo root." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${LOCAL_CONFIG}"

readonly MODEL_PATH LANGUAGE THREADS

# Loopback port the daemon listens on. Picked deliberately outside the common
# dev-server ports (3000/8000/8080/8888) to dodge collisions.
: "${STREAM_SERVER_PORT:=8472}"
readonly STREAM_SERVER_PORT

# Repo-local scratch directory — all transient artefacts go here, never /tmp.
readonly TMP_DIR="${SCRIPT_DIR}/../tmp"

# Where the PID and log files live for the running daemon.
readonly PID_FILE="${TMP_DIR}/stream-server.pid"
readonly LOG_FILE="${TMP_DIR}/stream-server.log"

mkdir -p "${TMP_DIR}"

# Seconds to wait for the server to start accepting connections before
# giving up; the model load happens during this window.
readonly READY_TIMEOUT_S=20

# ───── helpers ───────────────────────────────────────────────────────────────

# Check whether the PID file points at a live process. Echoes the PID and
# returns 0 when alive; returns 1 otherwise.
function _running_pid() {
  if [[ ! -f "${PID_FILE}" ]]; then return 1; fi
  local pid
  pid="$(cat "${PID_FILE}")"
  if [[ -z "${pid}" ]] || ! kill -0 "${pid}" 2>/dev/null; then
    return 1
  fi
  echo "${pid}"
}

# Poll the server's /inference endpoint until it accepts connections or
# the timeout expires. whisper-server doesn't expose /health; /inference
# with no body returns 404, which is itself proof of life — any HTTP
# response (vs. a connection refused) means the listener is bound. We
# drop curl's -f so 4xx codes don't shortcut the loop to "not ready".
function _wait_ready() {
  local i=0 code
  while [[ "${i}" -lt "${READY_TIMEOUT_S}" ]]; do
    code="$(curl -s -o /dev/null -w "%{http_code}" \
            "http://127.0.0.1:${STREAM_SERVER_PORT}/inference" 2>/dev/null \
            || echo "000")"
    if [[ "${code}" != "000" ]]; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# ───── subcommands ────────────────────────────────────────────────────────────

# Spawn whisper-server in the background and wait for it to accept requests.
# No-op if a previous PID file points to a live process.
function start() {
  if _running_pid >/dev/null; then
    echo "stream-server: already running on port ${STREAM_SERVER_PORT}"
    return 0
  fi
  if [[ ! -f "${MODEL_PATH}" ]]; then
    echo "stream-server: model not found at ${MODEL_PATH}" >&2
    return 1
  fi
  nohup whisper-server \
    --host 127.0.0.1 \
    --port "${STREAM_SERVER_PORT}" \
    --model "${MODEL_PATH}" \
    --language "${LANGUAGE}" \
    --threads "${THREADS}" \
    --no-timestamps \
    >"${LOG_FILE}" 2>&1 &
  echo "${!}" > "${PID_FILE}"
  if ! _wait_ready; then
    echo "stream-server: did not come up within ${READY_TIMEOUT_S}s; see ${LOG_FILE}" >&2
    return 1
  fi
  echo "stream-server: ready on http://127.0.0.1:${STREAM_SERVER_PORT}/inference (PID $(cat "${PID_FILE}"))"
}

# Send SIGTERM to the daemon and clean up the PID file. Safe to call
# repeatedly — exits 0 even if nothing was running.
function stop() {
  if ! _running_pid >/dev/null; then
    rm -f "${PID_FILE}"
    return 0
  fi
  local pid
  pid="$(cat "${PID_FILE}")"
  kill -TERM "${pid}" 2>/dev/null || true
  local i=0
  while kill -0 "${pid}" 2>/dev/null && [[ "${i}" -lt 5 ]]; do
    sleep 0.5
    i=$((i + 1))
  done
  if kill -0 "${pid}" 2>/dev/null; then
    kill -KILL "${pid}" 2>/dev/null || true
  fi
  rm -f "${PID_FILE}"
}

# Print the current state. Exit code follows: 0 running, 1 stopped.
function status() {
  local pid
  if pid="$(_running_pid)"; then
    echo "running PID ${pid} on port ${STREAM_SERVER_PORT}"
    return 0
  fi
  echo "stopped"
  return 1
}

# ───── entry point ────────────────────────────────────────────────────────────

# Dispatch first positional argument to the matching subcommand.
function main() {
  local cmd="${1:-}"
  case "${cmd}" in
    start)  shift; start "$@" ;;
    stop)   stop ;;
    status) status ;;
    *)
      echo "usage: stream-server.sh {start|stop|status}" >&2
      exit 1
      ;;
  esac
}

main "$@"
