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

2. **Detect URL type** and fetch the title using the appropriate method:
   - **WeChat article** (`mp.weixin.qq.com`): use the WeChat sub-skill below
   - **All other URLs**: use `WebFetch` on the URL, extract `<title>` or first `<h1>`
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

---

## Sub-skill: WeChat Article Fetcher

Handles URLs matching `mp.weixin.qq.com`. WeChat blocks normal browser requests with a captcha but allows requests with a WeChat mobile User-Agent.

### Detection

URL contains `mp.weixin.qq.com/s/`

### Fetch

Use `curl` with the WeChat mobile User-Agent via Bash:

```bash
curl -sL -A "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.43" "<url>"
```

**Do NOT use WebFetch** — it will trigger WeChat's captcha.

### Extract title

Parse the HTML output to find the title. Try these patterns in order:

1. `og:title` meta tag: `<meta property="og:title" content="..." />`
2. `msg_title` JS variable: `var msg_title = "..."`
3. `rich_media_title` class: `<h1 class="rich_media_title">...</h1>`

Remember to unescape HTML entities in the extracted title.

### Extract body (for issue body)

The article content is inside `<div id="js_content">...</div>`. Strip HTML tags to get plain text. Include the first 200 characters as a preview in the issue body, followed by the URL:

```
<first 200 chars of article text>...

<url>
```

---

## Examples

```
/reading-list https://engineering.uber.com/how-uber-optimized-cassandra/
```
-> WebFetch, extracts title "How Uber Optimized Cassandra Operations"
-> Creates issue in TommyCpp/tach with label `to-read`
-> Replies: "Added to reading list: *How Uber Optimized Cassandra Operations*"

```
https://mp.weixin.qq.com/s/ORh99rOnuV7mjxP6YfEHfw
```
-> Detected as WeChat article, uses curl with WeChat UA
-> Extracts title from og:title
-> Creates issue with preview in body
-> Replies: "Added to reading list: *一个周末 + 1100 美元...*"
