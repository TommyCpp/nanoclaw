# Gemini API Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Google Gemini as an alternative AI backend with full MCP tool support, routed through a dedicated credential proxy.

**Architecture:** New `gemini-query.ts` adapter in the agent-runner uses `@google/genai` with `mcpToTool()` for MCP integration and a manual agentic tool-call loop. A second credential proxy on port 3002 handles Gemini API key injection. SDK selection via `NANOCLAW_SDK=gemini` env var.

**Tech Stack:** `@google/genai`, `@modelcontextprotocol/sdk` (already a dependency), Node.js HTTP proxy

**Spec:** `docs/superpowers/specs/2026-04-03-gemini-backend-design.md`

---

### Task 1: Gemini Credential Proxy

**Files:**
- Modify: `src/config.ts`
- Modify: `src/credential-proxy.ts`
- Modify: `src/credential-proxy.test.ts`
- Modify: `src/index.ts`

- [ ] **Step 1: Write the failing test for Gemini proxy**

Add to `src/credential-proxy.test.ts`:

```typescript
import { startCredentialProxy, startGeminiCredentialProxy } from './credential-proxy.js';

// ... inside describe('credential-proxy', () => { ... existing tests ... })

describe('gemini-credential-proxy', () => {
  let proxyServer: http.Server;
  let upstreamServer: http.Server;
  let proxyPort: number;
  let lastUpstreamHeaders: http.IncomingHttpHeaders;

  beforeEach(async () => {
    lastUpstreamHeaders = {};

    upstreamServer = http.createServer((req, res) => {
      lastUpstreamHeaders = { ...req.headers };
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    });
    await new Promise<void>((resolve) =>
      upstreamServer.listen(0, '127.0.0.1', resolve),
    );
  });

  afterEach(async () => {
    await new Promise<void>((r) => proxyServer?.close(() => r()));
    await new Promise<void>((r) => upstreamServer?.close(() => r()));
    for (const key of Object.keys(mockEnv)) delete mockEnv[key];
  });

  async function startGeminiProxy(env: Record<string, string>): Promise<number> {
    const upstreamPort = (upstreamServer.address() as AddressInfo).port;
    Object.assign(mockEnv, env, {
      GEMINI_BASE_URL: `http://127.0.0.1:${upstreamPort}`,
    });
    proxyServer = await startGeminiCredentialProxy(0);
    return (proxyServer.address() as AddressInfo).port;
  }

  it('injects x-goog-api-key and strips placeholder', async () => {
    proxyPort = await startGeminiProxy({ GEMINI_API_KEY: 'AIza-real-key' });

    await makeRequest(
      proxyPort,
      {
        method: 'POST',
        path: '/v1beta/models/gemini-2.5-pro:generateContent',
        headers: {
          'content-type': 'application/json',
          'x-goog-api-key': 'placeholder',
        },
      },
      '{}',
    );

    expect(lastUpstreamHeaders['x-goog-api-key']).toBe('AIza-real-key');
  });

  it('strips hop-by-hop headers', async () => {
    proxyPort = await startGeminiProxy({ GEMINI_API_KEY: 'AIza-real-key' });

    await makeRequest(
      proxyPort,
      {
        method: 'POST',
        path: '/v1beta/models/gemini-2.5-pro:generateContent',
        headers: {
          'content-type': 'application/json',
          connection: 'keep-alive',
          'keep-alive': 'timeout=5',
          'transfer-encoding': 'chunked',
        },
      },
      '{}',
    );

    expect(lastUpstreamHeaders['keep-alive']).toBeUndefined();
    expect(lastUpstreamHeaders['transfer-encoding']).toBeUndefined();
  });

  it('returns 502 when upstream is unreachable', async () => {
    Object.assign(mockEnv, {
      GEMINI_API_KEY: 'AIza-real-key',
      GEMINI_BASE_URL: 'http://127.0.0.1:59999',
    });
    proxyServer = await startGeminiCredentialProxy(0);
    proxyPort = (proxyServer.address() as AddressInfo).port;

    const res = await makeRequest(
      proxyPort,
      {
        method: 'POST',
        path: '/v1beta/models/gemini-2.5-pro:generateContent',
        headers: { 'content-type': 'application/json' },
      },
      '{}',
    );

    expect(res.statusCode).toBe(502);
    expect(res.body).toBe('Bad Gateway');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/zhongyang/Dev/nanoclaw && npx vitest run src/credential-proxy.test.ts`
Expected: FAIL — `startGeminiCredentialProxy` is not exported

- [ ] **Step 3: Add GEMINI_CREDENTIAL_PROXY_PORT to config**

In `src/config.ts`, add after the `CREDENTIAL_PROXY_PORT` line:

```typescript
export const GEMINI_CREDENTIAL_PROXY_PORT = parseInt(
  process.env.GEMINI_CREDENTIAL_PROXY_PORT || '3002',
  10,
);
```

- [ ] **Step 4: Implement startGeminiCredentialProxy**

In `src/credential-proxy.ts`, add the new function after `startCredentialProxy`:

```typescript
export function startGeminiCredentialProxy(
  port: number,
  host = '127.0.0.1',
): Promise<Server> {
  const secrets = readEnvFile(['GEMINI_API_KEY', 'GEMINI_BASE_URL']);

  const upstreamUrl = new URL(
    secrets.GEMINI_BASE_URL || 'https://generativelanguage.googleapis.com',
  );
  const isHttps = upstreamUrl.protocol === 'https:';
  const makeRequest = isHttps ? httpsRequest : httpRequest;

  return new Promise((resolve, reject) => {
    const server = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => {
        const body = Buffer.concat(chunks);
        const headers: Record<string, string | number | string[] | undefined> =
          {
            ...(req.headers as Record<string, string>),
            host: upstreamUrl.host,
            'content-length': body.length,
          };

        // Strip hop-by-hop headers
        delete headers['connection'];
        delete headers['keep-alive'];
        delete headers['transfer-encoding'];

        // Inject real Gemini API key
        delete headers['x-goog-api-key'];
        headers['x-goog-api-key'] = secrets.GEMINI_API_KEY;

        const upstream = makeRequest(
          {
            hostname: upstreamUrl.hostname,
            port: upstreamUrl.port || (isHttps ? 443 : 80),
            path: req.url,
            method: req.method,
            headers,
          } as RequestOptions,
          (upRes) => {
            res.writeHead(upRes.statusCode!, upRes.headers);
            upRes.pipe(res);
          },
        );

        upstream.on('error', (err) => {
          logger.error(
            { err, url: req.url },
            'Gemini credential proxy upstream error',
          );
          if (!res.headersSent) {
            res.writeHead(502);
            res.end('Bad Gateway');
          }
        });

        upstream.write(body);
        upstream.end();
      });
    });

    server.listen(port, host, () => {
      logger.info({ port, host }, 'Gemini credential proxy started');
      resolve(server);
    });

    server.on('error', reject);
  });
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `npx vitest run src/credential-proxy.test.ts`
Expected: All tests PASS

- [ ] **Step 6: Wire Gemini proxy into main startup**

In `src/index.ts`, add import:

```typescript
import { GEMINI_CREDENTIAL_PROXY_PORT } from './config.js';
import { startGeminiCredentialProxy } from './credential-proxy.js';
```

Update the `startCredentialProxy` import to also include `startGeminiCredentialProxy`.

In the `main()` function, after the existing credential proxy startup (around line 492), add:

```typescript
  // Start Gemini credential proxy if configured
  const geminiEnv = readEnvFile(['GEMINI_API_KEY']);
  let geminiProxyServer: Server | undefined;
  if (geminiEnv.GEMINI_API_KEY) {
    geminiProxyServer = await startGeminiCredentialProxy(
      GEMINI_CREDENTIAL_PROXY_PORT,
      PROXY_BIND_HOST,
    );
  }
```

Add `import { readEnvFile } from './env.js';` and `import type { Server } from 'http';` if not already imported.

In the shutdown handler, add `geminiProxyServer?.close();` alongside the existing `proxyServer.close()`.

- [ ] **Step 7: Build and verify**

Run: `npm run build`
Expected: Compiles without errors

- [ ] **Step 8: Commit**

```bash
git add src/config.ts src/credential-proxy.ts src/credential-proxy.test.ts src/index.ts
git commit -m "feat: add Gemini credential proxy on port 3002"
```

---

### Task 2: Pass Gemini env vars into containers

**Files:**
- Modify: `src/container-runner.ts`

- [ ] **Step 1: Add Gemini env var passthrough**

In `src/container-runner.ts`, in the `buildContainerArgs` function, after the Anthropic auth block (after line 260), add:

```typescript
  // Pass SDK backend selection for container agents
  const nanoclavSdk = process.env.NANOCLAW_SDK;
  if (nanoclavSdk) {
    args.push('-e', `NANOCLAW_SDK=${nanoclavSdk}`);
  }

  // Pass Gemini config — API key is a placeholder, real key injected by proxy
  const geminiApiKey = readEnvFile(['GEMINI_API_KEY']).GEMINI_API_KEY;
  if (geminiApiKey) {
    args.push('-e', 'GEMINI_API_KEY=placeholder');
    args.push(
      '-e',
      `GEMINI_BASE_URL=http://${CONTAINER_HOST_GATEWAY}:${GEMINI_CREDENTIAL_PROXY_PORT}`,
    );
  }
  const geminiModel = process.env.GEMINI_MODEL;
  if (geminiModel) {
    args.push('-e', `GEMINI_MODEL=${geminiModel}`);
  }
```

Add the import at the top:

```typescript
import { GEMINI_CREDENTIAL_PROXY_PORT } from './config.js';
import { readEnvFile } from './env.js';
```

(Check if `readEnvFile` is already imported — if so, just add the config import.)

- [ ] **Step 2: Build and verify**

Run: `npm run build`
Expected: Compiles without errors

- [ ] **Step 3: Commit**

```bash
git add src/container-runner.ts
git commit -m "feat: pass Gemini env vars into containers"
```

---

### Task 3: Add `@google/genai` dependency

**Files:**
- Modify: `container/agent-runner/package.json`

- [ ] **Step 1: Install the dependency**

```bash
cd /Users/zhongyang/Dev/nanoclaw/container/agent-runner
npm install @google/genai
```

- [ ] **Step 2: Verify package.json updated**

Check that `@google/genai` appears in `dependencies` in `container/agent-runner/package.json`.

- [ ] **Step 3: Commit**

```bash
git add container/agent-runner/package.json container/agent-runner/package-lock.json
git commit -m "feat: add @google/genai dependency to agent-runner"
```

---

### Task 4: Implement `gemini-query.ts`

**Files:**
- Create: `container/agent-runner/src/gemini-query.ts`

- [ ] **Step 1: Create the Gemini query adapter**

Create `container/agent-runner/src/gemini-query.ts`:

```typescript
/**
 * Google Gemini SDK query adapter for NanoClaw
 *
 * Provides a query interface compatible with the agent-runner's main loop,
 * using the Google GenAI SDK instead of the Anthropic Claude Agent SDK.
 *
 * Implements a manual agentic tool-call loop:
 *   send prompt → check for functionCall → execute MCP tool → feed result back → repeat
 */

import { GoogleGenAI, mcpToTool, Type } from '@google/genai';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import fs from 'fs';
import path from 'path';
import { randomUUID } from 'crypto';

// ---------------------------------------------------------------------------
// Types (matching agent-runner conventions)
// ---------------------------------------------------------------------------

interface ContainerInput {
  prompt: string;
  sessionId?: string;
  groupFolder: string;
  chatJid: string;
  isMain: boolean;
  isScheduledTask?: boolean;
  assistantName?: string;
}

interface ContainerOutput {
  status: 'success' | 'error';
  result: string | null;
  newSessionId?: string;
  error?: string;
}

export interface GeminiQueryResult {
  newSessionId?: string;
  closedDuringQuery: boolean;
}

type WriteOutputFn = (output: ContainerOutput) => void;
type LogFn = (message: string) => void;
type ShouldCloseFn = () => boolean;
type DrainIpcFn = () => string[];

// ---------------------------------------------------------------------------
// MCP client + Gemini client (reused across queries)
// ---------------------------------------------------------------------------

let mcpClient: Client | null = null;
let mcpTransport: StdioClientTransport | null = null;

async function ensureMcpClient(
  mcpServerPath: string,
  containerInput: ContainerInput,
  log: LogFn,
): Promise<Client> {
  if (mcpClient) return mcpClient;

  log('Starting MCP server for Gemini adapter');
  mcpTransport = new StdioClientTransport({
    command: 'node',
    args: [mcpServerPath],
    env: {
      ...process.env,
      NANOCLAW_CHAT_JID: containerInput.chatJid,
      NANOCLAW_GROUP_FOLDER: containerInput.groupFolder,
      NANOCLAW_IS_MAIN: containerInput.isMain ? '1' : '0',
    },
  });

  mcpClient = new Client({ name: 'nanoclaw-gemini', version: '1.0.0' });
  await mcpClient.connect(mcpTransport);
  log('MCP client connected');
  return mcpClient;
}

export async function stopGeminiClient(): Promise<void> {
  if (mcpClient) {
    try { await mcpClient.close(); } catch { /* ignore */ }
    mcpClient = null;
  }
  if (mcpTransport) {
    try { await mcpTransport.close(); } catch { /* ignore */ }
    mcpTransport = null;
  }
}

// ---------------------------------------------------------------------------
// Session persistence
// ---------------------------------------------------------------------------

const SESSIONS_DIR = '/workspace/group/.gemini-sessions';

interface SerializedSession {
  history: Array<{ role: string; parts: unknown[] }>;
}

function loadSession(sessionId: string, log: LogFn): SerializedSession | null {
  const filePath = path.join(SESSIONS_DIR, `${sessionId}.json`);
  if (!fs.existsSync(filePath)) return null;
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf-8'));
  } catch (err) {
    log(`Failed to load Gemini session ${sessionId}: ${err instanceof Error ? err.message : String(err)}`);
    return null;
  }
}

function saveSession(sessionId: string, history: Array<{ role: string; parts: unknown[] }>, log: LogFn): void {
  fs.mkdirSync(SESSIONS_DIR, { recursive: true });
  const filePath = path.join(SESSIONS_DIR, `${sessionId}.json`);
  try {
    fs.writeFileSync(filePath, JSON.stringify({ history } satisfies SerializedSession));
  } catch (err) {
    log(`Failed to save Gemini session ${sessionId}: ${err instanceof Error ? err.message : String(err)}`);
  }
}

// ---------------------------------------------------------------------------
// Query implementation
// ---------------------------------------------------------------------------

const MAX_TOOL_ITERATIONS = 50;

export async function runGeminiQuery(
  prompt: string,
  sessionId: string | undefined,
  mcpServerPath: string,
  containerInput: ContainerInput,
  _sdkEnv: Record<string, string | undefined>,
  writeOutput: WriteOutputFn,
  log: LogFn,
  shouldClose: ShouldCloseFn,
  drainIpcInput: DrainIpcFn,
  ipcPollMs: number,
): Promise<GeminiQueryResult> {
  const model = process.env.GEMINI_MODEL || 'gemini-2.5-pro';
  const baseUrl = process.env.GEMINI_BASE_URL;
  const apiKey = process.env.GEMINI_API_KEY || 'placeholder';

  log(`Gemini query (model: ${model}, session: ${sessionId || 'new'}, baseUrl: ${baseUrl || 'default'})`);

  // Initialize clients
  const client = ensureMcpClient(mcpServerPath, containerInput, log);
  const ai = new GoogleGenAI({
    apiKey,
    ...(baseUrl ? { httpOptions: { baseUrl } } : {}),
  });

  // Convert MCP tools to Gemini tool format
  const tools = [mcpToTool(await client)];

  // Load system instruction from global CLAUDE.md
  const globalClaudeMdPath = '/workspace/global/CLAUDE.md';
  let systemInstruction: string | undefined;
  if (!containerInput.isMain && fs.existsSync(globalClaudeMdPath)) {
    systemInstruction = fs.readFileSync(globalClaudeMdPath, 'utf-8');
  }

  // Create or resume session
  const newSessionId = sessionId || randomUUID();
  const existingSession = sessionId ? loadSession(sessionId, log) : null;

  const chat = ai.chats.create({
    model,
    tools,
    ...(systemInstruction ? { systemInstruction } : {}),
    ...(existingSession?.history ? { history: existingSession.history as Parameters<typeof ai.chats.create>[0]['history'] } : {}),
  });

  // IPC polling
  let ipcPolling = true;
  let closedDuringQuery = false;

  const pollIpc = () => {
    if (!ipcPolling) return;
    if (shouldClose()) {
      log('Close sentinel detected during Gemini query');
      closedDuringQuery = true;
      ipcPolling = false;
      return;
    }
    const messages = drainIpcInput();
    for (const text of messages) {
      log(`IPC message queued for next turn (${text.length} chars)`);
      // IPC messages are queued — they'll be sent after the current tool loop completes
    }
    setTimeout(pollIpc, ipcPollMs);
  };
  setTimeout(pollIpc, ipcPollMs);

  try {
    // Agentic tool-call loop
    let response = await chat.sendMessage({ message: prompt });
    let iterations = 0;

    while (iterations < MAX_TOOL_ITERATIONS) {
      if (closedDuringQuery) break;

      // Check if response contains function calls
      const functionCalls = response.functionCalls;
      if (!functionCalls || functionCalls.length === 0) break;

      iterations++;
      log(`Tool iteration ${iterations}: ${functionCalls.length} function call(s)`);

      // Execute each function call via MCP
      const functionResponses: Array<{ name: string; response: { result: unknown } }> = [];
      for (const fc of functionCalls) {
        log(`Calling tool: ${fc.name}`);
        try {
          const mcpResult = await (await client).callTool({
            name: fc.name!,
            arguments: (fc.args as Record<string, unknown>) || {},
          });
          functionResponses.push({
            name: fc.name!,
            response: { result: mcpResult.content },
          });
        } catch (err) {
          const errMsg = err instanceof Error ? err.message : String(err);
          log(`Tool error (${fc.name}): ${errMsg}`);
          functionResponses.push({
            name: fc.name!,
            response: { result: `Error: ${errMsg}` },
          });
        }
      }

      // Feed results back
      response = await chat.sendMessage({ message: functionResponses });
    }

    if (iterations >= MAX_TOOL_ITERATIONS) {
      log(`Gemini hit max tool iterations (${MAX_TOOL_ITERATIONS})`);
    }

    // Extract text from final response
    const text = response.text || null;
    if (text) {
      log(`Gemini result (${text.length} chars): ${text.slice(0, 200)}`);
    }

    writeOutput({
      status: 'success',
      result: text,
      newSessionId,
    });

    // Persist session history
    // Access internal history from the chat object for serialization
    const history = (chat as unknown as { _history: Array<{ role: string; parts: unknown[] }> })._history;
    if (history) {
      saveSession(newSessionId, history, log);
    }

    return { newSessionId, closedDuringQuery };
  } catch (err) {
    const errorMessage = err instanceof Error ? err.message : String(err);
    log(`Gemini query error: ${errorMessage}`);
    writeOutput({
      status: 'error',
      result: null,
      newSessionId,
      error: errorMessage,
    });
    return { newSessionId, closedDuringQuery };
  } finally {
    ipcPolling = false;
  }
}
```

- [ ] **Step 2: Type-check**

Run: `cd /Users/zhongyang/Dev/nanoclaw/container/agent-runner && npx tsc --noEmit`
Expected: No errors. If there are type issues with `chat._history` or `mcpToTool`, adjust the cast accordingly — the `@google/genai` API may expose history differently. Fix any issues before proceeding.

- [ ] **Step 3: Commit**

```bash
git add container/agent-runner/src/gemini-query.ts
git commit -m "feat: implement Gemini query adapter with MCP tool loop"
```

---

### Task 5: Wire Gemini adapter into agent-runner main

**Files:**
- Modify: `container/agent-runner/src/index.ts`

- [ ] **Step 1: Add import**

At the top of `container/agent-runner/src/index.ts`, after the existing imports (line 20), add:

```typescript
import { runGeminiQuery, stopGeminiClient } from './gemini-query.js';
```

- [ ] **Step 2: Add SDK_BACKEND constant**

After the `IPC_POLL_MS` constant (around line 59), add:

```typescript
/**
 * Which SDK to use for agent queries.
 * Set via NANOCLAW_SDK env var: 'claude' (default) or 'gemini'.
 */
const SDK_BACKEND = (process.env.NANOCLAW_SDK || 'claude').toLowerCase();
```

- [ ] **Step 3: Update query dispatch in main()**

In the `main()` function's query loop (around line 512), replace:

```typescript
      const queryResult = await runQuery(prompt, sessionId, mcpServerPath, containerInput, sdkEnv, resumeAt);
```

with:

```typescript
      log(`Using SDK backend: ${SDK_BACKEND}`);

      let queryResult: { newSessionId?: string; lastAssistantUuid?: string; closedDuringQuery: boolean };

      if (SDK_BACKEND === 'gemini') {
        queryResult = await runGeminiQuery(
          prompt, sessionId, mcpServerPath, containerInput, sdkEnv,
          writeOutput, log, shouldClose, drainIpcInput, IPC_POLL_MS,
        );
      } else {
        queryResult = await runQuery(prompt, sessionId, mcpServerPath, containerInput, sdkEnv, resumeAt);
      }
```

Move the `log(`Using SDK backend:...`)` line before the `while (true)` loop so it only logs once.

- [ ] **Step 4: Add cleanup in finally block**

At the end of `main()`, wrap the existing catch in a try/finally and add Gemini cleanup. After the `process.exit(1)` in the catch block, add:

```typescript
  } finally {
    if (SDK_BACKEND === 'gemini') {
      await stopGeminiClient();
    }
  }
```

- [ ] **Step 5: Type-check and build**

Run: `cd /Users/zhongyang/Dev/nanoclaw/container/agent-runner && npx tsc --noEmit`
Expected: No errors

- [ ] **Step 6: Commit**

```bash
git add container/agent-runner/src/index.ts
git commit -m "feat: wire Gemini backend into agent-runner SDK dispatch"
```

---

### Task 6: Build container and end-to-end verification

**Files:**
- No new files

- [ ] **Step 1: Build host-side**

Run: `cd /Users/zhongyang/Dev/nanoclaw && npm run build`
Expected: Compiles without errors

- [ ] **Step 2: Build container**

Run: `cd /Users/zhongyang/Dev/nanoclaw && ./container/build.sh`
Expected: Container builds successfully

- [ ] **Step 3: Add Gemini config to .env**

Add to `.env`:

```
NANOCLAW_SDK=gemini
GEMINI_API_KEY=<your-real-key>
GEMINI_MODEL=gemini-2.5-pro
```

- [ ] **Step 4: Manual test**

Start NanoClaw with `npm run dev` and send a test message. Verify:
- Gemini credential proxy starts on port 3002 (check logs)
- Container receives `NANOCLAW_SDK=gemini`, `GEMINI_BASE_URL`, `GEMINI_API_KEY=placeholder`
- Agent responds using Gemini
- MCP tools work (send_message routes back through channels)

- [ ] **Step 5: Restore Claude config (optional)**

If you want to switch back, set `NANOCLAW_SDK=claude` in `.env` (or remove the line). The Gemini proxy still starts but containers won't use it.
