#!/usr/bin/env bash
# @fileoverview Background watchdog for ghost ffmpeg processes.
#
# Polls `pgrep` every INTERVAL seconds and appends a timestamped line to
# the repo-local tmp/ghost-watch.log every time the set of ffmpeg-recording
# PIDs changes (project rule: never /tmp; see CLAUDE.md § Scratch paths).
# Detects the bug where Hammerspoon's stopRecording fails to kill ffmpeg,
# leaving a process recording forever.
#
# Usage:
#   ./bin/monitor-ghosts.sh start      # spawn in background, pid -> .pid file
#   ./bin/monitor-ghosts.sh stop       # terminate the background watcher
#   ./bin/monitor-ghosts.sh status     # print whether watcher is running
#   ./bin/monitor-ghosts.sh tail       # `tail -f` the log
#   ./bin/monitor-ghosts.sh reset      # truncate log + clear pid file
#
# Each log line is one of:
#   <ts> START pid=<n> wav=<path> wav_size=<bytes> age_s=<n>
#   <ts> GONE  pid=<n> lifetime_s=<n>
#   <ts> WAV   pid=<n> wav=<path> size=<bytes>     # every TICK while alive

set -euo pipefail

# Repo-local scratch directory — all transient artefacts go here, never /tmp.
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TMP_DIR="${SCRIPT_DIR}/../tmp"
mkdir -p "${TMP_DIR}"

# Where the watchdog writes its observations.
readonly LOG_FILE="${TMP_DIR}/ghost-watch.log"

# Where the watchdog stores its own PID when running in background mode.
readonly PID_FILE="${TMP_DIR}/ghost-watch.pid"

# Seconds between polls. Sub-second resolution is overkill for this bug.
readonly INTERVAL=0.5

# Print one ISO-8601 timestamp with millisecond precision for log lines.
function ts() {
  date '+%Y-%m-%d %H:%M:%S.%3N'
}

# Return ffmpeg-voice-dictate PIDs, one per line. Empty if none.
function ghost_pids() {
  pgrep -f 'ffmpeg.*voice-dictate' 2>/dev/null || true
}

# Return the WAV path passed as the last arg to the given PID's command line.
# Falls back to "?" if the PID has gone away mid-read.
function wav_path_for() {
  local pid="${1}"
  ps -o command= -p "${pid}" 2>/dev/null \
    | awk '{print $NF}' \
    || echo "?"
}

# Byte count of <path>; 0 if missing.
function file_size() {
  local path="${1}"
  if [[ -f "${path}" ]]; then
    stat -f%z "${path}" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# Watcher loop: tracks known PIDs in associative arrays, emits START/GONE/WAV
# whenever state changes. Writes to LOG_FILE; never exits except on SIGTERM.
function watch_loop() {
  declare -A known_start_ts=()
  declare -A known_wav=()
  while true; do
    local now_epoch
    now_epoch="$(date +%s)"
    local current_pids
    current_pids="$(ghost_pids)"
    declare -A seen=()
    if [[ -n "${current_pids}" ]]; then
      while IFS= read -r pid; do
        [[ -z "${pid}" ]] && continue
        seen["${pid}"]=1
        if [[ -z "${known_start_ts[${pid}]:-}" ]]; then
          local wav
          wav="$(wav_path_for "${pid}")"
          known_start_ts["${pid}"]="${now_epoch}"
          known_wav["${pid}"]="${wav}"
          local size
          size="$(file_size "${wav}")"
          echo "$(ts) START pid=${pid} wav=${wav} wav_size=${size}" >> "${LOG_FILE}"
        else
          local wav="${known_wav[${pid}]}"
          local size
          size="$(file_size "${wav}")"
          local age=$((now_epoch - known_start_ts[${pid}]))
          echo "$(ts) WAV   pid=${pid} wav=${wav} size=${size} age_s=${age}" >> "${LOG_FILE}"
        fi
      done <<< "${current_pids}"
    fi
    for pid in "${!known_start_ts[@]}"; do
      if [[ -z "${seen[${pid}]:-}" ]]; then
        local lifetime=$((now_epoch - known_start_ts[${pid}]))
        echo "$(ts) GONE  pid=${pid} lifetime_s=${lifetime}" >> "${LOG_FILE}"
        unset 'known_start_ts[${pid}]'
        unset 'known_wav[${pid}]'
      fi
    done
    sleep "${INTERVAL}"
  done
}

# Spawn watch_loop in background, save the PID, exit.
function cmd_start() {
  if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
    echo "monitor-ghosts: already running (pid $(cat "${PID_FILE}"))" >&2
    exit 1
  fi
  echo "$(ts) MONITOR_START interval=${INTERVAL}s" >> "${LOG_FILE}"
  ( watch_loop ) &
  local bg_pid="${!}"
  echo "${bg_pid}" > "${PID_FILE}"
  disown "${bg_pid}" 2>/dev/null || true
  echo "monitor-ghosts: started (pid ${bg_pid}, log ${LOG_FILE})"
}

# Stop the background watcher if running.
function cmd_stop() {
  if [[ ! -f "${PID_FILE}" ]]; then
    echo "monitor-ghosts: not running" >&2
    return 0
  fi
  local pid
  pid="$(cat "${PID_FILE}")"
  if kill -0 "${pid}" 2>/dev/null; then
    kill -TERM "${pid}" 2>/dev/null || true
    echo "$(ts) MONITOR_STOP pid=${pid}" >> "${LOG_FILE}"
    echo "monitor-ghosts: stopped (pid ${pid})"
  else
    echo "monitor-ghosts: pidfile points at ${pid} but process is gone"
  fi
  rm -f "${PID_FILE}"
}

# Print status to stdout.
function cmd_status() {
  if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
    echo "monitor-ghosts: running (pid $(cat "${PID_FILE}"), log ${LOG_FILE})"
  else
    echo "monitor-ghosts: not running"
  fi
}

# `tail -f` the log; Ctrl+C to exit.
function cmd_tail() {
  : > "${LOG_FILE}" 2>/dev/null || true
  tail -f "${LOG_FILE}"
}

# Wipe log + pidfile to start clean.
function cmd_reset() {
  rm -f "${PID_FILE}" "${LOG_FILE}"
  echo "monitor-ghosts: log and pidfile cleared"
}

function main() {
  local cmd="${1:-}"
  case "${cmd}" in
    start)  cmd_start ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    tail)   cmd_tail ;;
    reset)  cmd_reset ;;
    *)
      echo "usage: monitor-ghosts.sh {start|stop|status|tail|reset}" >&2
      exit 1
      ;;
  esac
}

main "$@"
