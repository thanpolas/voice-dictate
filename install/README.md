# install — switchboard

Helper scripts sourced by the top-level orchestrator. One bootstrapper concern per helper. Stubs today; behaviour lands per the [install UX bootstrap plan](../engineering/plans/2026-05-25-install-ux-bootstrap.md).

## Contents

- [lib.sh](lib.sh) — Shared interactive prompt, logging, and command-presence helpers used by every other install helper.
- [deps.sh](deps.sh) — Homebrew detection and bootstrap; per-dependency install prompts; brew install dispatch.
- [model.sh](model.sh) — Whisper model discovery across known locations and resumable download to project-local storage.
- [hammerspoon.sh](hammerspoon.sh) — Symlink the Lua modules, patch the user's init script, and trigger a Hammerspoon reload.
- [config.sh](config.sh) — Generate the shell-side and Lua-side runtime configuration files from prompted values.
- [migration.sh](migration.sh) — Version-to-version migration entry point invoked by the orchestrator's update flow.
