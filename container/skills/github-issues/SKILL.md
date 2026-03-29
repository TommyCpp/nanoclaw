---
name: github-issues
description: Read and manage GitHub issues for allowlisted repos. Use when the user runs /github-issues or asks about GitHub issues, PRs (issues only), or wants to create/close/comment on issues.
---

# /github-issues — GitHub Issue Management

Read and manage GitHub issues for repos listed in `config/allowed-repos.json`.

**Main-channel check:** Only the main channel supports this command.

```bash
test -d /workspace/project && echo "MAIN" || echo "NOT_MAIN"
```

If `NOT_MAIN`, reply:
> This command is available in your main chat only.

Then stop.

## Allowlist

Repos must be listed in `config/allowed-repos.json` on the host (e.g. `["owner/repo1", "owner/repo2"]`). If a repo isn't listed, the operation will fail with an error — tell the user to add it to that file.

## Available Tools

| Tool | Purpose |
|------|---------|
| `mcp__nanoclaw__list_issues` | List open/closed issues with optional filters |
| `mcp__nanoclaw__get_issue` | Get full details + comments for one issue |
| `mcp__nanoclaw__create_issue` | Create a new issue |
| `mcp__nanoclaw__comment_issue` | Add a comment to an issue |
| `mcp__nanoclaw__close_issue` | Close an issue |
| `mcp__nanoclaw__reopen_issue` | Reopen a closed issue |
| `mcp__nanoclaw__add_labels` | Add labels to an issue |
| `mcp__nanoclaw__set_assignees` | Set assignees on an issue |

## Examples

**List open issues:**
```
mcp__nanoclaw__list_issues({ repo: "owner/myrepo", state: "open" })
```

**Get issue details:**
```
mcp__nanoclaw__get_issue({ repo: "owner/myrepo", issue_number: 42 })
```

**Create issue:**
```
mcp__nanoclaw__create_issue({
  repo: "owner/myrepo",
  title: "Bug: something is broken",
  body: "Steps to reproduce...",
  labels: ["bug"],
  assignees: ["username"]
})
```

**Close an issue:**
```
mcp__nanoclaw__close_issue({ repo: "owner/myrepo", issue_number: 42 })
```

**Add labels:**
```
mcp__nanoclaw__add_labels({ repo: "owner/myrepo", issue_number: 42, labels: ["priority-high"] })
```

## Results

All tools send their result back to chat asynchronously. The raw JSON from `gh issue ...` is forwarded as-is for list/view operations. For create/edit operations, a brief confirmation is sent.

## Repo Not Allowlisted?

If you get "Repo X is not in the allowlist", tell the user:
> To use GitHub tools for `owner/repo`, add it to `config/allowed-repos.json` on the host machine and restart is NOT needed — it takes effect immediately.
