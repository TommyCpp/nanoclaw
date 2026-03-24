---
name: cc-session
description: Start, stop, or list Claude Code remote-control sessions on the host machine. Use when the user runs /cc-session, /cc-session-stop, or /cc-session-list.
---

# /cc-session — Claude Code Remote Session

Start or reconnect to a Claude Code remote-control session on the host machine.

## Step 1 — Show what's available

Run both commands in parallel and present the results:

```bash
ls ~/Dev/ 2>/dev/null && echo "---" && mcp__nanoclaw__list_cc_sessions
```

Actually, run these separately:

1. List available projects:
```bash
ls ~/Dev/ 2>/dev/null || echo "(empty)"
```

2. Call `mcp__nanoclaw__list_cc_sessions` to show any active sessions.

Present to the user:
- Active sessions (if any) — offer to reconnect
- Available `~/Dev/` directories — offer to start new

## Step 2 — Start or reconnect

If the user picks an active session directory → call `mcp__nanoclaw__start_cc_session` with that path (it will reconnect automatically).

If the user picks a new directory → call `mcp__nanoclaw__start_cc_session` with `~/Dev/<dirname>`.

Tell the user:
> Starting/reconnecting Claude Code session for `<directory>`… link coming shortly.

## Notes

- Sessions survive NanoClaw restarts (run in tmux on the host)
- Reconnect works: if the remote-control disconnected, calling start again restarts it in the same tmux window
- Use `/cc-session-stop <path>` to terminate a session
