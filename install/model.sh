#!/usr/bin/env bash
# @fileoverview Whisper model discovery and download. Scans known locations
# and any path set in bin/config.local.sh before falling back to a resumable
# download into .local/models/. Never duplicates a model file the user
# already has on disk.

set -euo pipefail

# Search known locations for an existing usable Whisper model.
# Echoes the resolved absolute path to stdout when found; returns non-zero otherwise.
function find_existing_model() {
  echo "todo: find_existing_model" >&2
  exit 1
}

# Download the configured Whisper model with resume support.
# $1 — destination path inside .local/models/ where the model should land.
function download_model() {
  echo "todo: download_model" >&2
  exit 1
}
