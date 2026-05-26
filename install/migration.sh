#!/usr/bin/env bash
# @fileoverview Version-to-version migration entry point. Called by
# install.sh update to bridge config schema changes, file moves, and
# deprecation warnings between the currently-installed tag and the new tag.
# Per-version migrations live inside this file until the file approaches its
# soft cap, at which point they split into install/migrations/.

set -euo pipefail

# Run the migration steps that bridge from_tag to to_tag.
# $1 — from_tag, the currently-installed release tag read from .local/state/version.
# $2 — to_tag, the release tag the user is upgrading to.
function migrate() {
  echo "todo: migrate" >&2
  exit 1
}
