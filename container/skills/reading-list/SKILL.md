---
name: reading-list
description: Queue URLs to the reading list. Invoke when the user sends /reading-list <url>, or when a message is just a bare URL with no other text.
---

# /reading-list — Add to Reading List

Save articles for later by creating a GitHub issue in TommyCpp/tach with the `to-read` label.

**Main-channel only.** Check:

```bash
test -d /workspace/project && echo "MAIN" || echo "NOT_MAIN"
```

If `NOT_MAIN`, reply: "This command is available in your main chat only." Then stop.

## Triggers

1. **Explicit**: `/reading-list <url>`
2. **Auto**: message is a bare URL (starts with `http://` or `https://`, no other text)

## Steps

1. **Extract the URL** from the message.

2. **Fetch the page title**:
   - Use `WebFetch` on the URL
   - Extract the `<title>` tag or first `<h1>` from the page content
   - If fetch fails (paywall, timeout, etc.), derive a fallback title from the URL path segments (e.g. `https://example.com/blog/my-post` -> "my-post")

3. **Create a GitHub issue** using the MCP tool:
   ```
   mcp__nanoclaw__create_issue({
     repo: "TommyCpp/tach",
     title: "<extracted title>",
     body: "<url>",
     labels: ["to-read"]
   })
   ```

4. **Reply** to the user: "Added to reading list: *<title>*"

   Note: The issue creation is asynchronous. The MCP tool returns immediately with a confirmation, and the actual issue URL will be sent to chat by the host once created.

## Examples

```
/reading-list https://engineering.uber.com/how-uber-optimized-cassandra/
```
-> Fetches page, extracts title "How Uber Optimized Cassandra Operations"
-> Creates issue in TommyCpp/tach with label `to-read`
-> Replies: "Added to reading list: *How Uber Optimized Cassandra Operations*"

```
https://arxiv.org/abs/2401.12345
```
-> Bare URL detected, auto-triggers reading list
-> Same flow as above
