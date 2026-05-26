#!/usr/bin/env bash
# @fileoverview macOS permissions walkthrough. Opens the Accessibility,
# Input Monitoring, and Microphone panes of System Settings in sequence and
# pauses between each so the user can grant Hammerspoon the permissions it
# needs to run unattended.

set -euo pipefail

# Walk the user through enabling the three System Settings panes Hammerspoon needs.
# Prompts between each pane so the user can confirm completion or skip.
function walk_permissions() {
  echo "todo: walk_permissions" >&2
  exit 1
}
