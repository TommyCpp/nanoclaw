# Test Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a local HTTP test channel so a CC session can send messages to NanoClaw and observe responses end-to-end, with isolated context and per-test session reset.

**Architecture:** A new `TestChannel` registers as a standard channel with JID `test:local` and group folder `test-local`. It spins up a localhost-only HTTP server exposing three endpoints: POST to send a message, GET to drain the response buffer, and DELETE to reset the session. Session reset requires clearing both the SQLite record and the in-memory map in `index.ts`, passed in as a `clearSession` callback via `ChannelOpts`.

**Tech Stack:** Node.js `http` (built-in, no new deps), existing `registerChannel` / `ChannelOpts` pattern, `better-sqlite3` (already in use)

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `src/channels/test.ts` | TestChannel class + HTTP server + `registerChannel` call |
| Modify | `src/channels/index.ts` | Import test channel so it self-registers |
| Modify | `src/channels/registry.ts` | Add optional `clearSession?` to `ChannelOpts` |
| Modify | `src/db.ts` | Add `deleteSession(folder)` function |
| Modify | `src/index.ts` | Pass `clearSession` in channelOpts |

---

### Task 1: Add `deleteSession` to `db.ts`

**Files:**
- Modify: `src/db.ts` (after `setSession` at line ~527)

- [ ] **Step 1: Add the function**

Insert after `setSession`:

```typescript
export function deleteSession(groupFolder: string): void {
  db.prepare('DELETE FROM sessions WHERE group_folder = ?').run(groupFolder);
}
```

- [ ] **Step 2: Build to verify no type errors**

```bash
npm run build 2>&1 | tail -5
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add src/db.ts
git commit -m "feat: add deleteSession to db"
```

---

### Task 2: Add `clearSession` to `ChannelOpts`

**Files:**
- Modify: `src/channels/registry.ts`

- [ ] **Step 1: Extend the interface**

```typescript
export interface ChannelOpts {
  onMessage: OnInboundMessage;
  onChatMetadata: OnChatMetadata;
  registeredGroups: () => Record<string, RegisteredGroup>;
  clearSession?: (folder: string) => void;
}
```

- [ ] **Step 2: Build**

```bash
npm run build 2>&1 | tail -5
```
Expected: no errors (field is optional, existing callers unaffected).

- [ ] **Step 3: Commit**

```bash
git add src/channels/registry.ts
git commit -m "feat: add optional clearSession to ChannelOpts"
```

---

### Task 3: Wire `clearSession` in `index.ts`

**Files:**
- Modify: `src/index.ts` (around line ~691 where `channelOpts` is built)

- [ ] **Step 1: Find the channelOpts block**

Look for:
```typescript
registeredGroups: () => registeredGroups,
```
It is the last field of the `channelOpts` object (around line 691).

- [ ] **Step 2: Add clearSession**

```typescript
    registeredGroups: () => registeredGroups,
    clearSession: (folder: string) => {
      delete sessions[folder];
      deleteSession(folder);
    },
```

- [ ] **Step 3: Import `deleteSession`**

Add `deleteSession` to the import from `./db.js` (around line 20):

```typescript
import {
  // ... existing imports ...
  deleteSession,
  // ...
} from './db.js';
```

- [ ] **Step 4: Build**

```bash
npm run build 2>&1 | tail -5
```
Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add src/index.ts
git commit -m "feat: wire clearSession into channelOpts"
```

---

### Task 4: Implement `TestChannel`

**Files:**
- Create: `src/channels/test.ts`

The channel:
- JID: `test:local`
- Group folder: `test-local`
- Only starts when `TEST_CHANNEL_ENABLED=true` in `.env`
- HTTP on `127.0.0.1:TEST_CHANNEL_PORT` (default `8765`)
- Buffers outbound messages; GET drains the buffer
- Always registers and marks the group on connect (like iOS channel does)

- [ ] **Step 1: Write the file**

```typescript
import { createServer, IncomingMessage, ServerResponse } from 'http';

import { setRegisteredGroup } from '../db.js';
import { readEnvFile } from '../env.js';
import { logger } from '../logger.js';
import { registerChannel, ChannelOpts } from './registry.js';
import { Channel, OnChatMetadata, OnInboundMessage } from '../types.js';

const TEST_JID = 'test:local';
const TEST_FOLDER = 'test-local';

interface TestChannelOpts {
  onMessage: OnInboundMessage;
  onChatMetadata: OnChatMetadata;
  clearSession?: (folder: string) => void;
  port: number;
}

export class TestChannel implements Channel {
  name = 'test';

  private opts: TestChannelOpts;
  private buffer: string[] = [];
  private connected = false;

  constructor(opts: TestChannelOpts) {
    this.opts = opts;
  }

  async connect(): Promise<void> {
    this.ensureGroupRegistered();

    const server = createServer((req: IncomingMessage, res: ServerResponse) => {
      this.handleRequest(req, res);
    });

    await new Promise<void>((resolve) => {
      server.listen(this.opts.port, '127.0.0.1', () => {
        this.connected = true;
        logger.info({ port: this.opts.port }, 'Test channel listening');
        console.log(`\n  Test channel: http://127.0.0.1:${this.opts.port}\n`);
        resolve();
      });
    });
  }

  private ensureGroupRegistered(): void {
    setRegisteredGroup(TEST_JID, {
      name: 'Test',
      folder: TEST_FOLDER,
      trigger: '@test',
      added_at: new Date().toISOString(),
      requiresTrigger: false,
    });
  }

  private handleRequest(req: IncomingMessage, res: ServerResponse): void {
    const url = req.url ?? '/';
    const method = req.method ?? 'GET';

    // POST /message — send a message into the agent
    if (method === 'POST' && url === '/message') {
      let body = '';
      req.on('data', (chunk) => { body += chunk; });
      req.on('end', () => {
        let text: string;
        try {
          const parsed = JSON.parse(body);
          if (typeof parsed.text !== 'string' || !parsed.text.trim()) {
            res.writeHead(400, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'text required' }));
            return;
          }
          text = parsed.text.trim();
        } catch {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'invalid JSON' }));
          return;
        }

        const msgId = `test-${Date.now()}`;
        this.opts.onChatMetadata(TEST_JID, new Date().toISOString(), 'Test', 'test', false);
        this.opts.onMessage(TEST_JID, {
          id: msgId,
          chat_jid: TEST_JID,
          sender: 'test-user',
          sender_name: 'Test',
          content: text,
          timestamp: new Date().toISOString(),
          is_from_me: false,
        });

        res.writeHead(202, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, id: msgId }));
      });
      return;
    }

    // GET /messages — drain response buffer
    if (method === 'GET' && url === '/messages') {
      const messages = this.buffer.splice(0);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ messages }));
      return;
    }

    // DELETE /session — clear session so next message starts fresh
    if (method === 'DELETE' && url === '/session') {
      this.opts.clearSession?.(TEST_FOLDER);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'not found' }));
  }

  async sendMessage(_jid: string, text: string): Promise<void> {
    this.buffer.push(text);
    logger.debug({ length: text.length }, 'Test channel: buffered outbound message');
  }

  isConnected(): boolean {
    return this.connected;
  }

  ownsJid(jid: string): boolean {
    return jid === TEST_JID;
  }

  async disconnect(): Promise<void> {
    this.connected = false;
  }
}

registerChannel('test', (opts: ChannelOpts) => {
  const envVars = readEnvFile(['TEST_CHANNEL_ENABLED', 'TEST_CHANNEL_PORT']);
  const enabled =
    (process.env.TEST_CHANNEL_ENABLED || envVars.TEST_CHANNEL_ENABLED) === 'true';
  if (!enabled) return null;

  const port = parseInt(
    process.env.TEST_CHANNEL_PORT || envVars.TEST_CHANNEL_PORT || '8765',
    10,
  );

  return new TestChannel({
    onMessage: opts.onMessage,
    onChatMetadata: opts.onChatMetadata,
    clearSession: opts.clearSession,
    port,
  });
});
```

- [ ] **Step 2: Build**

```bash
npm run build 2>&1 | tail -10
```
Expected: no errors.

---

### Task 5: Register the test channel

**Files:**
- Modify: `src/channels/index.ts`

- [ ] **Step 1: Add import**

```typescript
// test (local dev only — enabled via TEST_CHANNEL_ENABLED=true)
import './test.js';
```

- [ ] **Step 2: Build**

```bash
npm run build 2>&1 | tail -5
```
Expected: no errors.

- [ ] **Step 3: Commit tasks 4 + 5 together**

```bash
git add src/channels/test.ts src/channels/index.ts
git commit -m "feat: add local HTTP test channel"
```

---

### Task 6: Enable and smoke test

- [ ] **Step 1: Add to `.env`**

```bash
echo "TEST_CHANNEL_ENABLED=true" >> .env
echo "TEST_CHANNEL_PORT=8765" >> .env
```

- [ ] **Step 2: Start dev server**

```bash
npm run dev
```
Expected output includes: `Test channel: http://127.0.0.1:8765`

- [ ] **Step 3: Send a message**

In a second terminal:
```bash
curl -s -X POST http://127.0.0.1:8765/message \
  -H 'Content-Type: application/json' \
  -d '{"text": "hello, what is 2+2?"}' | jq .
```
Expected: `{ "ok": true, "id": "test-..." }`

- [ ] **Step 4: Poll for response (agent takes a few seconds)**

```bash
sleep 15 && curl -s http://127.0.0.1:8765/messages | jq .
```
Expected: `{ "messages": ["4"] }` or similar agent reply.

- [ ] **Step 5: Reset session between tests**

```bash
curl -s -X DELETE http://127.0.0.1:8765/session | jq .
```
Expected: `{ "ok": true }`

Send another message — agent should have no memory of the first exchange.

- [ ] **Step 6: Commit env note (do NOT commit `.env` itself)**

```bash
# Add to .env.example or README if one exists, otherwise skip
git status  # confirm .env is gitignored
```

---

## Usage pattern for skill testing

```bash
# 1. Reset session (clean slate)
curl -s -X DELETE http://127.0.0.1:8765/session

# 2. Send test message
curl -s -X POST http://127.0.0.1:8765/message \
  -H 'Content-Type: application/json' \
  -d '{"text": "/github-issues list TommyCpp/nanoclaw"}'

# 3. Wait and collect response
sleep 20
curl -s http://127.0.0.1:8765/messages | jq -r '.messages[]'
```
