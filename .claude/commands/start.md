---
description: Start a new Dikta session — load INVENTORY.md, engineering rules, and current product state
---

You are starting a new Dikta session. Execute the following steps in order.

## Step 1 — Confirm CLAUDE.md is loaded

`CLAUDE.md` is auto-loaded by Claude Code on every session start and its rules are already in effect — CDE, comments, markdown, naming, file and function caps, Conventional Commits. You do not need to read it during this command; treat it as active background context throughout the session.

## Step 2 — Read the master switchboard

- [INVENTORY.md](../../INVENTORY.md) — the root map of the repo. Orient from it.

## Step 3 — Read the engineering rules in depth

- [engineering/cde.md](../../engineering/cde.md) — Context-Driven Engineering, operating rule, switchboard discipline.
- [engineering/conventions.md](../../engineering/conventions.md) — file/function caps, naming, comments, markdown, commits, Lua and shell specifics.

## Step 4 — Load current product state

- [engineering/plans/README.md](../../engineering/plans/README.md) — switchboard for dated plans and the frozen v0.1 spec. Read it, then open the most recent plan plus any older plan referenced by the task at hand.
- Folder README for any area implied by the task — [bin/README.md](../../bin/README.md) for shell work, [hammerspoon/README.md](../../hammerspoon/README.md) for Lua work.

## Step 5 — CDE compliance check

Verify [INVENTORY.md](../../INVENTORY.md) is current:

- List the top-level folders and key files you can observe in the repo.
- Cross-reference against what INVENTORY.md documents.
- Flag any folder or file that exists but is missing from the inventory, or any inventory entry that no longer exists.
- If drift is found, note it in the briefing and fix INVENTORY.md before ending this step.

## Step 6 — Present session briefing

Output a concise briefing with:

- **Context loaded** — bullet list of every file read.
- **Active plan** — name the most recent dated plan in `engineering/plans/`, state whether it has open questions or is settled, and call out anything the user should know before picking up work.
- **CDE status** — either "INVENTORY.md is current" or what was out of date and what you fixed.
- **Ready** — confirm orientation and ask: "What are we working on?"

## Your CDE responsibility throughout this session

You own inventory accuracy. Whenever a file or folder is created, renamed, or removed during this session:

- Update INVENTORY.md to reflect the change before the session ends.
- Never let the inventory drift from the actual repo state.
