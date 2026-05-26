#!/usr/bin/env bash
# @fileoverview Whisper model discovery and download. Detects existing models
# under known paths (configured MODEL_PATH first, then ~/whisper-models/)
# before falling back to a resumable curl download into the project-local
# .local/models/ directory. Never duplicates a model file the user already
# has on disk.

set -euo pipefail

# Source lib.sh from the same directory so log() and confirm() are available.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Default model file name used when downloading; matches the README/spec default.
readonly VD_DEFAULT_MODEL_FILENAME="ggml-large-v3-turbo-q5_0.bin"

# Canonical download URL for the default model on Hugging Face.
readonly VD_DEFAULT_MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${VD_DEFAULT_MODEL_FILENAME}"

# Search known locations for an existing usable Whisper model.
# Honours the configured path first, then scans ~/whisper-models/ for any
# .bin checkpoint. Echoes the resolved absolute path on success; returns 1
# when nothing usable is found.
# $1 — optional configured path (typically MODEL_PATH from config.local.sh).
function find_existing_model() {
  local configured="${1:-}"
  if [[ -n "${configured}" && -f "${configured}" ]]; then
    echo "${configured}"
    return 0
  fi
  local search_dir="${HOME}/whisper-models"
  if [[ -d "${search_dir}" ]]; then
    local first
    first="$(find "${search_dir}" -maxdepth 1 -type f -name "*.bin" 2>/dev/null | head -n1)"
    if [[ -n "${first}" ]]; then
      echo "${first}"
      return 0
    fi
  fi
  return 1
}

# Download the default Whisper model with resume support.
# Uses curl -C - so partial downloads from a previous run pick up where they
# left off; --fail aborts on HTTP errors instead of writing a 4xx page to disk.
# $1 — destination path inside .local/models/ where the model should land.
function download_model() {
  local destination="${1}"
  mkdir -p "$(dirname "${destination}")"
  log info "downloading ${VD_DEFAULT_MODEL_FILENAME} (~547 MB; resumable on retry)"
  curl -L --fail -C - --progress-bar -o "${destination}" "${VD_DEFAULT_MODEL_URL}"
  log ok "model saved to ${destination}"
}

# Resolve a usable model path, downloading the default on consent if needed.
# This is the high-level entry point called by the orchestrator; the lower
# helpers above are exposed for callers that need finer-grained control.
# Echoes the absolute path of the model that should be used.
# $1 — configured MODEL_PATH (may be empty); checked first.
# $2 — fallback destination path inside .local/models/ for the default download.
function ensure_model() {
  local configured="${1:-}"
  local fallback_destination="${2}"
  local existing
  if existing="$(find_existing_model "${configured}")"; then
    log info "reusing existing model: ${existing}"
    echo "${existing}"
    return 0
  fi
  log warn "no Whisper model found on disk."
  echo "voice-dictate needs a Whisper model (~547 MB) to transcribe audio." >&2
  echo "Default: ${VD_DEFAULT_MODEL_FILENAME} — Greek + English, ~5x realtime on M-series." >&2
  echo "Will be saved to: ${fallback_destination}" >&2
  if ! confirm "Download the default model now?" y; then
    log error "model is required. Provide one manually and re-run install.sh."
    exit 1
  fi
  download_model "${fallback_destination}"
  echo "${fallback_destination}"
}
