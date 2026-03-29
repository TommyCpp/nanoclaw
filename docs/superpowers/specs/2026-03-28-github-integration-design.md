# GitHub Integration Design

**Date:** 2026-03-28
**Scope:** Two new features — (1) clone/pull GitHub repos into `~/Dev/`, (2) full GitHub issue management for allowlisted repos.

---

## Overview

Both features follow the existing NanoClaw IPC pattern:
- Container agent calls an MCP tool → writes an IPC file
- Host `ipc.ts` picks up the IPC file → runs `gh` CLI on the real filesystem
- Result sent back to chat via `deps.sendMessage`
- Both features are **main-group only**

Authentication is handled entirely by the host's `gh` CLI (already authenticated). No tokens are exposed to the container.

---

## Feature 1: Clone/Pull Repos (`/pull-repo`)

### MCP Tool: `clone_repo`

Added to `container/agent-runner/src/ipc-mcp-stdio.ts`.

**Input:**
- `repo` (string): `owner/repo` shorthand or full `https://github.com/owner/repo` URL

**Behavior:**
- Main-only guard (same pattern as `start_cc_session`)
- Writes IPC file: `{ type: 'clone_repo', repo, chatJid, groupFolder, timestamp }`
- Returns immediately: "Clone/pull requested for `<repo>`. Result will be sent to chat."

### Host IPC Handler

Added to `src/ipc.ts`, handling `type: 'clone_repo'`.

**Logic:**
1. Resolve `targetDir = ~/Dev/<repo-basename>` (e.g. `owner/nanoclaw` → `~/Dev/nanoclaw`)
2. Expand `~` to `os.homedir()`
3. Create `~/Dev/` if it doesn't exist
4. If `targetDir` does not exist → `gh repo clone <repo> <targetDir>`
5. If `targetDir` exists and contains `.git/` → `git -C <targetDir> pull`
6. If `targetDir` exists but has no `.git/` → error: "Directory exists but is not a git repo"
7. Send result message to `chatJid`

**Security:** Uses `execFile` with args array (no shell interpolation). Main-only enforced at both MCP and IPC layers.

**Error handling:** Forward stderr from `gh`/`git` directly to chat on failure. Handle `gh` not found or not authenticated.

### Container Skill: `container/skills/pull-repo/SKILL.md`

- Trigger: user runs `/pull-repo` or asks to clone/pull a GitHub repo
- Main-channel check (same pattern as `cc-session`)
- Calls `mcp__nanoclaw__clone_repo` with the repo identifier
- Reports back the result from chat

---

## Feature 2: GitHub Issue Management (`/github-issues`)

### Allowlist File: `config/allowed-repos.json`

A JSON array of permitted repos:
```json
["owner/repo1", "owner/repo2"]
```

- Managed manually by the user (edit the file directly)
- Read by the host on every IPC call (no restart needed)
- Container never reads or writes this file
- If file doesn't exist or repo not listed → error message to chat

### MCP Tools

All added to `container/agent-runner/src/ipc-mcp-stdio.ts`. All are main-only. Each writes an IPC file and returns immediately; results are sent to chat.

| Tool | IPC type | Key inputs |
|------|----------|------------|
| `list_issues` | `gh_list_issues` | `repo`, `state` (open/closed/all), `labels`, `assignee`, `limit` |
| `get_issue` | `gh_get_issue` | `repo`, `issue_number` |
| `create_issue` | `gh_create_issue` | `repo`, `title`, `body`, `labels`, `assignees` |
| `comment_issue` | `gh_comment_issue` | `repo`, `issue_number`, `body` |
| `close_issue` | `gh_close_issue` | `repo`, `issue_number` |
| `reopen_issue` | `gh_reopen_issue` | `repo`, `issue_number` |
| `add_labels` | `gh_add_labels` | `repo`, `issue_number`, `labels` (array) |
| `set_assignees` | `gh_set_assignees` | `repo`, `issue_number`, `assignees` (array) |

### Host IPC Handler

Added to `src/ipc.ts`, handling all `gh_*` types via a shared dispatcher.

**Shared logic for all issue tools:**
1. Read `config/allowed-repos.json`
2. Validate `repo` is in the allowlist — if not, send error to chat and return
3. Run the appropriate `gh` CLI command using `execFile`
4. Send stdout (formatted) or stderr (on error) back to chat

**`gh` CLI commands used:**
```bash
gh issue list   --repo <repo> --state <state> --label <labels> --assignee <assignee> --limit <n> --json number,title,state,labels,assignees,createdAt
gh issue view   --repo <repo> <number> --json number,title,state,body,labels,assignees,comments
gh issue create --repo <repo> --title <title> --body <body> --label <labels> --assignee <assignees>
gh issue comment --repo <repo> <number> --body <body>
gh issue close  --repo <repo> <number>
gh issue reopen --repo <repo> <number>
gh issue edit   --repo <repo> <number> --add-label <labels>
gh issue edit   --repo <repo> <number> --assignee <assignees>
```

**Security:** All `gh` calls use `execFile` with args arrays. `repo` is validated against allowlist before any execution.

### Container Skill: `container/skills/github-issues/SKILL.md`

- Trigger: user runs `/github-issues` or asks about issues on a repo
- Main-channel check
- Guides the agent to call the appropriate `mcp__nanoclaw__*` tools
- Explains the allowlist: if a repo isn't listed, the user needs to add it to `config/allowed-repos.json`

---

## Files Changed

| File | Change |
|------|--------|
| `container/agent-runner/src/ipc-mcp-stdio.ts` | Add `clone_repo` + 8 issue MCP tools |
| `src/ipc.ts` | Add handlers for `clone_repo` + `gh_*` IPC types |
| `config/allowed-repos.json` | New file (created if not present, user-managed) |
| `container/skills/pull-repo/SKILL.md` | New skill |
| `container/skills/github-issues/SKILL.md` | New skill |

No changes to `src/container-runner.ts`, `src/index.ts`, or any channel code.

---

## Out of Scope

- PR management (separate feature if needed)
- Non-main group access
- Automatic CC session start after clone
- Web UI for allowlist management
