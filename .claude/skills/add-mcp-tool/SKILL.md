---
name: add-mcp-tool
description: How to add a new MCP tool to NanoClaw so the container agent can trigger actions on the host machine. Use when the user wants to add a new capability that requires host-side execution (file system, shell commands, external APIs).
---

# Adding a New MCP Tool to NanoClaw

NanoClaw MCP tools follow a two-layer pattern:

1. **Container side** (`ipc-mcp-stdio.ts`) — the MCP tool the agent calls. Writes an IPC file and returns immediately.
2. **Host side** (`src/ipc.ts`) — reads the IPC file and executes the actual work on the host, then sends the result back to chat.

The container never executes host commands directly. Everything goes through IPC files.

## Architecture

```
Agent calls mcp__nanoclaw__<tool>
  → ipc-mcp-stdio.ts writes JSON to /workspace/ipc/tasks/<file>.json
    → host ipc.ts picks up file, runs logic, calls deps.sendMessage()
      → result appears in chat
```

## Step 1 — Add the MCP tool in `ipc-mcp-stdio.ts`

File: `/workspace/project/container/agent-runner/src/ipc-mcp-stdio.ts`
(or `/app/src/ipc-mcp-stdio.ts` inside the container)

Add a `server.tool(...)` call. Keep it thin — just validate inputs, write an IPC file, and return immediately:

```typescript
server.tool(
  'my_tool',
  'Description of what this tool does.',
  {
    param1: z.string().describe('What this param does'),
    param2: z.number().optional().describe('Optional param'),
  },
  async (args) => {
    // Main-only guard (if needed)
    if (!isMain) {
      return {
        content: [{ type: 'text' as const, text: 'Only main group can use this.' }],
        isError: true,
      };
    }

    writeIpcFile(TASKS_DIR, {
      type: 'my_tool',          // must match the case in ipc.ts
      param1: args.param1,
      param2: args.param2,
      chatJid,
      groupFolder,
      timestamp: new Date().toISOString(),
    });

    return {
      content: [{ type: 'text' as const, text: 'Request sent. Result will appear in chat.' }],
    };
  },
);
```

## Step 2 — Add the IPC handler in `src/ipc.ts`

File: `/workspace/project/src/ipc.ts`

Extend the `data` type to include your new fields, then add a `case` in `processTaskIpc`:

```typescript
// In the data parameter type:
myParam?: string;

// In the switch statement (before `default:`):
case 'my_tool':
  if (!isMain) {
    logger.warn({ sourceGroup }, 'Unauthorized my_tool attempt blocked');
    break;
  }
  if (data.myParam) {
    const targetJid = data.chatJid || findMainJid(registeredGroups);
    if (targetJid) {
      // Do the actual work here (call a function, run a command, etc.)
      const result = await myFunction(data.myParam);
      await deps.sendMessage(targetJid, result.message);
    }
  }
  break;
```

For non-trivial logic, extract it into `src/my-module.ts` (like `src/github.ts` or `src/cc-session.ts`) and import it.

## Step 3 — Build and sync

```bash
# In the NanoClaw project root:
npm run build
```

The updated `ipc-mcp-stdio.ts` is synced to each group's `agent-runner-src/` automatically on next container start (source-newer-than-group check). No manual copy needed after the first time.

Restart the service to apply:
```bash
launchctl kickstart -k gui/$(id -u)/com.nanoclaw
# or on Linux:
systemctl --user restart nanoclaw
```

## Step 4 — Write tests

Add tests for the host handler in `src/ipc.ts`:
- Test that non-main is blocked
- Test that main triggers the right function and sends a message

See `src/github-ipc.test.ts` for the pattern (uses `vi.mock('./github.js')` to avoid real execution).

For the logic module (`src/my-module.ts`), add unit tests in `src/my-module.test.ts`. See `src/github.test.ts` for the pattern (mocks `child_process`).

## Example: The GitHub tools

The GitHub clone/issue tools in this install are a complete example:
- MCP tools: `clone_repo`, `list_issues`, `get_issue`, etc. in `ipc-mcp-stdio.ts`
- IPC types: `clone_repo`, `gh_list_issues`, etc. in `src/ipc.ts`
- Logic module: `src/github.ts`
- Tests: `src/github.test.ts`, `src/github-ipc.test.ts`

## Security notes

- **Main-only**: Most host operations should require `isMain`. Add the guard in both the MCP tool and the IPC handler.
- **execFile, not exec**: Use `execFile` with an args array — never `exec` with a shell string. Prevents injection.
- **Allowlists**: For operations on external resources (repos, APIs), validate against an allowlist on the host (not in the container). See `config/allowed-repos.json`.
- **No secrets in IPC**: Don't put credentials in IPC files. The container cannot read the host's `.env`.
