#!/usr/bin/env bash
#
# PreToolUse guard: forbid Edit / Write / NotebookEdit when the target
# file's git repository is currently on the protected `main` (or `master`)
# branch. Forces all edits onto a feature branch.
#
# Exit codes (Claude Code hook contract):
#   0 — allow the tool call
#   2 — block the tool call; stderr is fed back to Claude as the reason

set -u

# Tool input is provided either as JSON via $CLAUDE_TOOL_INPUT (current
# Claude Code), or via stdin (older / future variants). Try env first.
INPUT="${CLAUDE_TOOL_INPUT:-}"
if [ -z "$INPUT" ]; then
  INPUT="$(cat)"
fi

# Edit/Write use file_path; NotebookEdit uses notebook_path.
FILE="$(printf '%s' "$INPUT" | jq -r '.file_path // .notebook_path // empty' 2>/dev/null)"

# No path on this tool call → nothing to gate.
[ -n "$FILE" ] || exit 0

# Resolve the directory we should query git from. If the file does not yet
# exist (Write creating a new file), walk up to the nearest existing dir.
DIR="$FILE"
[ -d "$DIR" ] || DIR="$(dirname "$FILE")"
while [ -n "$DIR" ] && [ "$DIR" != "/" ] && [ ! -d "$DIR" ]; do
  DIR="$(dirname "$DIR")"
done

# Outside any directory we can reason about → allow.
[ -d "$DIR" ] || exit 0

# Find the enclosing git repo. Files outside any repo are not gated.
REPO="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO" ] || exit 0

# Current branch. Detached HEAD returns empty → treat as not-on-main.
BRANCH="$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[ -n "$BRANCH" ] || exit 0

case "$BRANCH" in
  main|master)
    cat >&2 <<EOF
BLOCKED by .claude/hooks/check-not-on-main.sh

Repository:    $REPO
Current branch: $BRANCH
Tool target:   $FILE

Edits to a protected branch are not allowed. Create or switch to a feature
branch before editing — e.g.:

  git checkout -b <type>/<short-name>

If this block is incorrect, fix the branch you're on. To bypass intentionally,
disable the hook in .claude/settings.json.
EOF
    exit 2
    ;;
  *)
    exit 0
    ;;
esac
