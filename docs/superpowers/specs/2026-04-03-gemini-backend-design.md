# Gemini API Backend for NanoClaw

## Overview

Add Google Gemini as an alternative AI backend, following the same adapter pattern established by the Copilot SDK PR (#1351). A new `gemini-query.ts` module implements the agentic tool-calling loop using `@google/genai`, with full MCP support via `mcpToTool()`.

## Architecture

### SDK Selection (existing pattern from #1351)

`container/agent-runner/src/index.ts` dispatches based on `NANOCLAW_SDK` env var:

```
NANOCLAW_SDK=claude  → runQuery()          (existing, default)
NANOCLAW_SDK=copilot → runCopilotQuery()   (from PR #1351)
NANOCLAW_SDK=gemini  → runGeminiQuery()    (new)
```

### New File: `container/agent-runner/src/gemini-query.ts`

Adapter that wraps `@google/genai` to match the agent-runner's query interface.

**Key components:**

1. **GoogleGenAI client** — singleton, initialized with `GEMINI_API_KEY`
2. **MCP integration** — `StdioClientTransport` + `Client` from `@modelcontextprotocol/sdk` to connect to the NanoClaw MCP server, then `mcpToTool()` from `@google/genai` to convert MCP tools into Gemini-compatible tool declarations
3. **Agentic tool loop** — since there's no high-level `query()`, we implement:
   - Send prompt via `chat.sendMessageStream()`
   - Check response for `functionCall` parts
   - If tool calls present: execute via MCP client, feed results back as `functionResponse` parts, loop
   - If text response: emit result via `writeOutput()`, done
4. **Session management** — `Chat` object holds multi-turn history in memory. Session ID maps to a serialized history file on disk (`/workspace/group/.gemini-sessions/<id>.json`) for cross-query resumption within the container lifecycle
5. **IPC piping** — same pattern as Copilot adapter: poll for IPC messages during query, inject as new user turns
6. **Close sentinel** — monitored during query, triggers graceful shutdown

### Changes to Existing Files

**`container/agent-runner/src/index.ts`:**
- Import `runGeminiQuery` and `stopGeminiClient`
- Add `else if (SDK_BACKEND === 'gemini')` branch in the query dispatch
- Call `stopGeminiClient()` in `finally` block (cleans up MCP client transport)

**`container/agent-runner/package.json`:**
- Add `@google/genai` dependency

**`src/container-runner.ts`:**
- Pass `GEMINI_API_KEY` and `GEMINI_MODEL` env vars into containers
- No credential proxy needed — Gemini uses its own API key directly, not the Anthropic proxy

### Configuration

```bash
# .env
NANOCLAW_SDK=gemini
GEMINI_API_KEY=AIza...
GEMINI_MODEL=gemini-2.5-pro  # optional, defaults to gemini-2.5-pro
```

## Agentic Loop Detail

```
User prompt
    ↓
chat.sendMessageStream(prompt)
    ↓
Response chunks arrive (streaming)
    ↓
Collect full response
    ↓
Has functionCall parts? ──no──→ Extract text → writeOutput() → done
    │
    yes
    ↓
For each functionCall:
  → call MCP tool via client.callTool()
  → collect result
    ↓
Send functionResponse parts back to chat
    ↓
Loop back to "Response chunks arrive"
```

Maximum tool-call iterations: 50 (safety limit, matching typical agent SDK behavior).

## MCP Server Lifecycle

The MCP server (`ipc-mcp-stdio.js`) is started as a child process via `StdioClientTransport` at the beginning of `runGeminiQuery()`. It stays alive for the duration of the query. On query end or container shutdown, the transport is closed.

This differs from the Claude SDK (which manages MCP servers internally) but matches what we need to do since we're driving the loop ourselves.

## Session Management

Since the Gemini SDK's `Chat` object is in-memory only:

1. After each query completes, serialize the chat history to `/workspace/group/.gemini-sessions/<sessionId>.json`
2. On resume, deserialize history and create a new `Chat` with that history
3. Session ID is a UUID generated on first query, returned to the host via `newSessionId`

This gives us cross-query session continuity within the container's IPC message loop.

## System Prompt

The global `CLAUDE.md` content (loaded from `/workspace/global/CLAUDE.md`) is passed as the `systemInstruction` parameter when creating the Gemini model instance.

## What This Does NOT Include

- No credential proxy changes (Gemini uses direct API key, not the Anthropic proxy)
- No pre-compact hook (Gemini doesn't have the same compaction model — we can add conversation archiving separately if needed)
- No agent teams support (Gemini doesn't have an equivalent — single agent only)

## Error Handling

- API errors (rate limits, auth failures) → logged + `writeOutput({ status: 'error', ... })`
- Tool execution errors → returned as error content in `functionResponse`, letting the model retry or report
- MCP server crash → caught, logged, query terminates with error

## Testing

- `npx tsc --noEmit` in agent-runner
- `npm run build` at root
- `./container/build.sh`
- Manual test with `NANOCLAW_SDK=gemini` set, verify MCP tools work (send_message, schedule_task)
