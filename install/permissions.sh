#!/usr/bin/env bash
# @fileoverview macOS permissions walkthrough. Opens the Accessibility, Input
# Monitoring, and Microphone panes of System Settings in sequence and pauses
# between each so the user can grant Hammerspoon the permissions it needs to
# run unattended. Silently-failing permissions are the #1 first-run friction
# — this helper exists so the install never offloads that discovery onto the
# user.

set -euo pipefail

# Source lib.sh from the same directory so log() is available.
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# x-apple.systempreferences base URL for the Security & Privacy preferences pane.
readonly VD_SECURITY_PANE_URL="x-apple.systempreferences:com.apple.preference.security"

# Walk the user through the three System Settings panes Hammerspoon needs.
# Opens each pane via the x-apple.systempreferences:// URL scheme, prints
# why the permission matters, and pauses for Enter (or 's' to skip) so the
# user can grant the permission in their own time.
function walk_permissions() {
  log info "Hammerspoon needs three macOS permissions to run unattended."
  echo "" >&2
  echo "For each pane that opens:" >&2
  echo "  1. If Hammerspoon is in the list, toggle it ON." >&2
  echo "  2. If NOT, click the [+] below the list, choose" >&2
  echo "     /Applications/Hammerspoon.app, then toggle it ON." >&2
  echo "  3. If macOS asks to quit and relaunch Hammerspoon, say yes." >&2
  echo "" >&2
  echo "Microphone is special: Hammerspoon won't appear in that pane until" >&2
  echo "the first dictation actually fires ffmpeg. Press 's' to skip it now;" >&2
  echo "macOS will prompt on first recording and add the row automatically." >&2
  echo "" >&2
  echo "Press Enter to confirm each pane, or 's' to skip." >&2
  echo "" >&2
  _prompt_for_pane "Accessibility" "Privacy_Accessibility" \
    "Required for the simulated Cmd+V paste (hs.eventtap.keyStroke)."
  _prompt_for_pane "Input Monitoring" "Privacy_ListenEvent" \
    "Required to capture the Right Option key globally for push-to-talk."
  _prompt_for_pane "Microphone" "Privacy_Microphone" \
    "Required for ffmpeg to capture audio when Hammerspoon spawns it. Skippable — macOS will prompt on first recording."
}

# Open a single System Settings pane and wait for user confirmation.
# Private helper — only walk_permissions calls this.
# $1 — display name of the pane (e.g. "Accessibility").
# $2 — anchor appended to the security URL (e.g. "Privacy_Accessibility").
# $3 — short reason why this permission is required.
function _prompt_for_pane() {
  local title="${1}"
  local anchor="${2}"
  local why="${3}"
  log info "${title} — ${why}"
  open "${VD_SECURITY_PANE_URL}?${anchor}" || true
  local answer
  read -r -p "Press Enter when Hammerspoon is added + enabled under ${title} (or 's' to skip): " answer
  if [[ "${answer}" == "s" || "${answer}" == "S" ]]; then
    log warn "skipped ${title}; voice-dictate may fail on first use."
  else
    log ok "${title} confirmed."
  fi
}
