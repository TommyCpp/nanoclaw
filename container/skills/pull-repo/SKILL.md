---
name: pull-repo
description: Clone a GitHub repo into ~/Dev/, or pull (update) it if it already exists. Use when the user runs /pull-repo or asks to clone/pull/update a GitHub repo.
---

# /pull-repo — Clone or Update a GitHub Repo

Clone a GitHub repo into `~/Dev/<repo-name>`, or pull (update) it if the directory already exists.

**Main-channel check:** Only the main channel supports this command.

```bash
test -d /workspace/project && echo "MAIN" || echo "NOT_MAIN"
```

If `NOT_MAIN`, reply:
> This command is available in your main chat only.

Then stop.

## Usage

Call `mcp__nanoclaw__clone_repo` with the repo identifier:

```
mcp__nanoclaw__clone_repo({ repo: "owner/repo" })
```

Accepts:
- Short form: `owner/repo` (e.g. `qwibitai/nanoclaw`)
- Full URL: `https://github.com/owner/repo`

## Behavior

- If `~/Dev/<repo-name>` does **not** exist → clones the repo there
- If `~/Dev/<repo-name>` exists and has `.git/` → runs `git pull` to update it
- If `~/Dev/<repo-name>` exists but has no `.git/` → returns an error

The result (success message or error) is sent back to chat automatically.

## Examples

User: "clone qwibitai/nanoclaw"
→ Call `mcp__nanoclaw__clone_repo({ repo: "qwibitai/nanoclaw" })`

User: "pull the latest changes for my-project"
→ If `my-project` is in `~/Dev/`, call `mcp__nanoclaw__clone_repo({ repo: "owner/my-project" })`

## After Cloning

Once cloned, you can start a Claude Code session with `/cc-session` to work in the repo.
