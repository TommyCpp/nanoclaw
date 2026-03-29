---
name: reading-list
description: Queue URLs to the tach reading list and trigger daily tach runs. Invoke when the user sends /reading-list <url>, or when a bare URL is shared with no other content.
---

# Reading List

Queue articles for later processing by tach, which summarizes them into the Obsidian vault.

## Triggers

This skill activates in two cases:

1. **Explicit**: user sends `/reading-list <url>`
2. **Auto**: user sends a bare URL (message is just a URL, nothing else)

## Link Intake

1. Extract the URL from the message
2. Fetch the page to get the title:
   ```
   WebFetch <url>  →  extract <title> or first <h1>
   ```
   If fetch fails (paywall, timeout, etc.), derive a fallback title from the URL path.
3. Create a GitHub issue:
   ```bash
   gh issue create --repo TommyCpp/tach --title "<title>" --body "<url>" --label "to-read"
   ```
4. Reply: `Added to reading list as issue #N`

## Daily Cron Setup

On first use, check whether the daily tach trigger is already scheduled:

```bash
sqlite3 /workspace/project/store/messages.db \
  "SELECT id FROM scheduled_tasks WHERE status = 'active' AND prompt LIKE '%tach%run%';"
```

If no rows are returned, register it via `mcp__nanoclaw__schedule_task`:

- **schedule_type**: `cron`
- **schedule_value**: `0 7 * * *`
- **context_mode**: `isolated`
- **prompt**:

```
Run the tach CLI to process today's reading list.

# TODO: replace with the actual tach CLI entry point once defined
cd /workspace/extra/tach && <tach-cli-command>
```

Once registered, do not register again.

## Notes

- Link intake works from any group — no tach mount required
- The daily cron task runs in a context where tach is mounted at `/workspace/extra/tach`
- tach handles all summarization logic; this skill only queues and triggers
