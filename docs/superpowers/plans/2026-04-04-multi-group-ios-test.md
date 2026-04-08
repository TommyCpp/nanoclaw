# Multi-Group iOS & Test Channels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add multi-group (channel) support to the iOS and test channels, allowing multiple isolated conversations over a single connection — matching how Discord already works.

**Architecture:** Both channels move from hard-coded single JIDs to dynamic `ios:{chatId}` / `test:{chatId}` JIDs. The iOS WebSocket protocol gains a `chatId` field on all frames (defaulting to `"main"` for backward compat). The test channel gains `/channels/{chatId}/message` and `/channels/{chatId}/messages` endpoints. One designated channel (`main`) keeps `isMain: true`.

**Tech Stack:** TypeScript, WebSocket (ws), Node.js HTTP server, SQLite (existing)

---

### File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/channels/ios.ts` | Modify | Multi-group WebSocket protocol with chatId multiplexing |
| `src/channels/test.ts` | Modify | Multi-group HTTP endpoints with chatId routing |

No new files needed — this is a focused change to two existing channel implementations.

---

### Task 1: Multi-Group Test Channel

The test channel is simpler (HTTP, no WebSocket state), so we implement it first and use it to verify the integration works end-to-end before touching iOS.

**Files:**
- Modify: `src/channels/test.ts`

- [ ] **Step 1: Update ownsJid and JID scheme**

Replace the hard-coded `TEST_JID` / `TEST_FOLDER` constants and `ownsJid` to support `test:{chatId}` pattern:

```typescript
// Remove these constants:
// const TEST_JID = 'test:local';
// const TEST_FOLDER = 'test-local';

// Add helper:
const DEFAULT_CHAT_ID = 'local';

function testJid(chatId: string): string {
  return `test:${chatId}`;
}

function testFolder(chatId: string): string {
  return `test-${chatId}`;
}
```

Update `ownsJid`:
```typescript
ownsJid(jid: string): boolean {
  return jid.startsWith('test:');
}
```

- [ ] **Step 2: Add ensureChannelRegistered helper**

Replace `ensureGroupRegistered()` with a generic version that registers any chatId:

```typescript
private ensureChannelRegistered(chatId: string, isMain: boolean): void {
  const jid = testJid(chatId);
  const groups = this.opts.registeredGroups();
  if (groups[jid]) return;

  const folder = testFolder(chatId);
  const group: RegisteredGroup = {
    name: `Test ${chatId}`,
    folder,
    trigger: '@test',
    added_at: new Date().toISOString(),
    requiresTrigger: false,
    isMain: isMain,
  };

  setRegisteredGroup(jid, group);
  groups[jid] = group;
  logger.info({ jid, folder }, 'Test channel: registered group');
}
```

Update `connect()` to register the default channel:
```typescript
async connect(): Promise<void> {
  this.ensureChannelRegistered(DEFAULT_CHAT_ID, true);
  // ... rest of server setup unchanged
}
```

- [ ] **Step 3: Add channel management endpoints**

Add these new routes in `handleRequest`:

```typescript
// POST /channels — create a new channel
if (method === 'POST' && url === '/channels') {
  let body = '';
  req.on('data', (chunk) => { body += chunk; });
  req.on('end', () => {
    let chatId: string;
    let name: string | undefined;
    try {
      const parsed = JSON.parse(body);
      chatId = parsed.chatId;
      name = parsed.name;
      if (typeof chatId !== 'string' || !chatId.trim()) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'chatId required' }));
        return;
      }
    } catch {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'invalid JSON' }));
      return;
    }

    chatId = chatId.trim();
    const folder = testFolder(chatId);
    if (!isValidGroupFolder(folder)) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'invalid chatId' }));
      return;
    }

    this.ensureChannelRegistered(chatId, false);
    const jid = testJid(chatId);
    res.writeHead(201, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, jid, folder, name: name || chatId }));
  });
  return;
}

// GET /channels — list all test channels
if (method === 'GET' && url === '/channels') {
  const groups = this.opts.registeredGroups();
  const channels = Object.entries(groups)
    .filter(([jid]) => jid.startsWith('test:'))
    .map(([jid, g]) => ({
      chatId: jid.replace(/^test:/, ''),
      name: g.name,
      folder: g.folder,
      isMain: g.isMain ?? false,
    }));
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ channels }));
  return;
}
```

- [ ] **Step 4: Update message endpoints to support chatId**

Update `POST /message` to accept an optional `chatId` field (defaults to `DEFAULT_CHAT_ID`):

```typescript
// In the POST /message handler, after parsing JSON:
const chatId = (typeof parsed.chatId === 'string' && parsed.chatId.trim())
  ? parsed.chatId.trim()
  : DEFAULT_CHAT_ID;
const jid = testJid(chatId);

// Ensure the channel is registered (auto-register on first message)
const groups = this.opts.registeredGroups();
if (!groups[jid]) {
  this.ensureChannelRegistered(chatId, false);
}

// Replace TEST_JID with jid in onChatMetadata and onMessage calls
this.opts.onChatMetadata(jid, new Date().toISOString(), `Test ${chatId}`, 'test', false);
this.opts.onMessage(jid, {
  id: msgId,
  chat_jid: jid,
  sender: 'test-user',
  sender_name: 'Test',
  content: text,
  timestamp: new Date().toISOString(),
  is_from_me: false,
});
```

- [ ] **Step 5: Update sendMessage and buffer to be per-channel**

Change `buffer` from `string[]` to `Map<string, string[]>`:

```typescript
private buffers = new Map<string, string[]>();

async sendMessage(jid: string, text: string): Promise<void> {
  const chatId = jid.replace(/^test:/, '');
  const buf = this.buffers.get(chatId) ?? [];
  buf.push(text);
  this.buffers.set(chatId, buf);
  logger.debug({ jid, length: text.length }, 'Test channel: buffered outbound message');
}
```

Update `GET /messages` to accept optional `?chatId=` query param:

```typescript
if (method === 'GET' && (url === '/messages' || url?.startsWith('/messages?'))) {
  const urlObj = new URL(url, `http://${req.headers.host}`);
  const chatId = urlObj.searchParams.get('chatId') ?? DEFAULT_CHAT_ID;
  const buf = this.buffers.get(chatId) ?? [];
  const messages = buf.splice(0);
  if (buf.length === 0) this.buffers.delete(chatId);
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ messages }));
  return;
}
```

- [ ] **Step 6: Update DELETE /session to support chatId**

```typescript
if (method === 'DELETE' && (url === '/session' || url?.startsWith('/session?'))) {
  const urlObj = new URL(url, `http://${req.headers.host}`);
  const chatId = urlObj.searchParams.get('chatId') ?? DEFAULT_CHAT_ID;
  this.opts.clearSession?.(testFolder(chatId));
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ ok: true }));
  return;
}
```

- [ ] **Step 7: Build and verify compilation**

Run: `npm run build`
Expected: Clean compilation, no errors.

- [ ] **Step 8: Manual smoke test with test channel**

Start NanoClaw with test channel enabled, then test:

```bash
# Send to default channel (backward compat)
curl -s -X POST http://127.0.0.1:8765/message -d '{"text":"hello default"}'

# Create a new channel
curl -s -X POST http://127.0.0.1:8765/channels -d '{"chatId":"work","name":"Work Channel"}'

# Send to specific channel
curl -s -X POST http://127.0.0.1:8765/message -d '{"text":"hello work","chatId":"work"}'

# List channels
curl -s http://127.0.0.1:8765/channels

# Get messages from specific channel
curl -s http://127.0.0.1:8765/messages?chatId=work
```

- [ ] **Step 9: Commit**

```bash
git add src/channels/test.ts
git commit -m "feat: add multi-group support to test channel"
```

---

### Task 2: Multi-Group iOS Channel

Now apply the same pattern to the iOS WebSocket channel, with multiplexed `chatId` on all frames.

**Files:**
- Modify: `src/channels/ios.ts`

- [ ] **Step 1: Replace hard-coded JID/folder with helpers**

```typescript
// Remove:
// const IOS_JID = 'ios:main';
// const IOS_FOLDER = 'ios-main';

// Add:
const DEFAULT_CHAT_ID = 'main';

function iosJid(chatId: string): string {
  return `ios:${chatId}`;
}

function iosFolder(chatId: string): string {
  return `ios-${chatId}`;
}
```

- [ ] **Step 2: Replace ensureGroupRegistered with ensureChannelRegistered**

```typescript
private ensureChannelRegistered(chatId: string, isMain: boolean): void {
  const jid = iosJid(chatId);
  const groups = this.opts.registeredGroups();
  if (groups[jid]) return;

  const folder = iosFolder(chatId);
  const group: RegisteredGroup = {
    name: `iOS ${chatId}`,
    folder,
    trigger: `@${ASSISTANT_NAME}`,
    added_at: new Date().toISOString(),
    requiresTrigger: false,
    isMain,
  };

  try {
    setRegisteredGroup(jid, group);
    groups[jid] = group;
    logger.info({ jid, folder }, 'iOS: registered channel');
  } catch (err) {
    logger.error({ err, jid }, 'iOS: failed to register channel');
  }
}
```

Update `connect()`:
```typescript
this.ensureChannelRegistered(DEFAULT_CHAT_ID, true);
```

- [ ] **Step 3: Update pending messages to be per-channel**

```typescript
// Replace:
// private pendingMessages: string[] = [];

// With:
private pendingMessages = new Map<string, string[]>();
```

- [ ] **Step 4: Update inbound message handling for chatId**

In the `ws.on('message')` handler, after the `msg.type === 'message'` check:

```typescript
if (msg.type === 'create_channel') {
  const chatId = typeof msg.chatId === 'string' ? msg.chatId.trim() : '';
  const name = typeof msg.name === 'string' ? msg.name.trim() : chatId;
  if (!chatId) {
    ws.send(JSON.stringify({ type: 'error', message: 'chatId required' }));
    return;
  }
  const folder = iosFolder(chatId);
  if (!isValidGroupFolder(folder)) {
    ws.send(JSON.stringify({ type: 'error', message: 'invalid chatId' }));
    return;
  }
  this.ensureChannelRegistered(chatId, false);
  ws.send(JSON.stringify({
    type: 'channel_created',
    chatId,
    name,
    folder,
  }));
  logger.info({ chatId }, 'iOS: channel created');
  return;
}

if (msg.type === 'list_channels') {
  const groups = this.opts.registeredGroups();
  const channels = Object.entries(groups)
    .filter(([jid]) => jid.startsWith('ios:'))
    .map(([jid, g]) => ({
      chatId: jid.replace(/^ios:/, ''),
      name: g.name,
      folder: g.folder,
      isMain: g.isMain ?? false,
    }));
  ws.send(JSON.stringify({ type: 'channels', channels }));
  return;
}
```

For the existing `msg.type === 'message'` handler, add chatId support:

```typescript
if (msg.type !== 'message' || typeof msg.text !== 'string') return;

const chatId = (typeof msg.chatId === 'string' && msg.chatId.trim())
  ? msg.chatId.trim()
  : DEFAULT_CHAT_ID;
const jid = iosJid(chatId);
const msgId = typeof msg.id === 'string' ? msg.id : randomUUID();
const content = msg.text.trim();
if (!content) return;

// Auto-register channel on first message
const groups = this.opts.registeredGroups();
if (!groups[jid]) {
  this.ensureChannelRegistered(chatId, false);
}

// Prepend trigger so the message loop picks it up
const routed = TRIGGER_PATTERN.test(content)
  ? content
  : `@${ASSISTANT_NAME} ${content}`;

this.opts.onChatMetadata(
  jid,
  new Date().toISOString(),
  `iOS ${chatId}`,
  'ios',
  false,
);
this.opts.onMessage(jid, {
  id: msgId,
  chat_jid: jid,
  sender: 'ios-user',
  sender_name: 'iOS',
  content: routed,
  timestamp: new Date().toISOString(),
  is_from_me: false,
});

logger.info({ msgId, chatId }, 'iOS: inbound message');
```

- [ ] **Step 5: Update sendMessage for per-channel routing**

```typescript
async sendMessage(jid: string, text: string): Promise<void> {
  const chatId = jid.replace(/^ios:/, '');
  const token = JSON.stringify({ type: 'token', text, chatId });
  const done = JSON.stringify({ type: 'done', chatId });
  const connected = [...this.clients].filter(
    (ws) => ws.readyState === WebSocket.OPEN,
  );
  if (connected.length === 0) {
    const buf = this.pendingMessages.get(chatId) ?? [];
    buf.push(token, done);
    this.pendingMessages.set(chatId, buf);
    logger.info(
      { chatId, buffered: buf.length, length: text.length },
      'iOS: no client connected, buffered message',
    );
    return;
  }
  for (const ws of connected) {
    ws.send(token);
    ws.send(done);
  }
  logger.info(
    { clients: connected.length, chatId, length: text.length },
    'iOS: message sent',
  );
}
```

- [ ] **Step 6: Update setTyping for chatId**

```typescript
async setTyping(jid: string, isTyping: boolean): Promise<void> {
  const chatId = jid.replace(/^ios:/, '');
  const payload = JSON.stringify({ type: 'typing', isTyping, chatId });
  for (const ws of this.clients) {
    if (ws.readyState === WebSocket.OPEN) ws.send(payload);
  }
}
```

- [ ] **Step 7: Update auth_ok pending flush to be per-channel**

In the auth handshake success block, flush all pending messages across all channels:

```typescript
if (msg.auth === this.opts.secret) {
  authenticated = true;
  this.clients.add(ws);

  let totalPending = 0;
  for (const buf of this.pendingMessages.values()) {
    totalPending += buf.length;
  }

  ws.send(JSON.stringify({ type: 'auth_ok', pending: totalPending }));
  logger.info(
    { ip: (req.socket as any).remoteAddress },
    'iOS client connected',
  );

  // Flush pending messages from all channels
  if (totalPending > 0) {
    logger.info({ count: totalPending }, 'iOS: flushing pending messages');
    for (const buf of this.pendingMessages.values()) {
      for (const pending of buf) {
        ws.send(pending);
      }
    }
    this.pendingMessages.clear();
  }
  return;  // Important: return after auth handling
}
```

- [ ] **Step 8: Add isValidGroupFolder import**

Add to the imports at top of file:

```typescript
import { isValidGroupFolder } from '../group-folder.js';
```

- [ ] **Step 9: Build and verify compilation**

Run: `npm run build`
Expected: Clean compilation, no errors.

- [ ] **Step 10: Commit**

```bash
git add src/channels/ios.ts
git commit -m "feat: add multi-group support to iOS channel"
```

---

### Task 3: End-to-End Smoke Test via Test Channel

- [ ] **Step 1: Start NanoClaw and test multi-group flow**

```bash
npm run dev &

# Wait for startup, then test:

# 1. Default channel still works (backward compat)
curl -s -X POST http://127.0.0.1:8765/message -d '{"text":"hello from default"}'
sleep 2
curl -s http://127.0.0.1:8765/messages

# 2. Create a new channel
curl -s -X POST http://127.0.0.1:8765/channels -d '{"chatId":"research","name":"Research"}'

# 3. Send to new channel
curl -s -X POST http://127.0.0.1:8765/message -d '{"text":"hello from research","chatId":"research"}'

# 4. Verify messages are isolated per channel
curl -s http://127.0.0.1:8765/messages?chatId=research
curl -s http://127.0.0.1:8765/messages

# 5. List all channels
curl -s http://127.0.0.1:8765/channels
```

Expected:
- Default channel messages don't leak into research channel
- `GET /channels` shows both `local` (isMain) and `research`
- Each channel has its own group folder in `groups/`

- [ ] **Step 2: Verify container isolation**

After sending a message to the `research` channel, check:
- `groups/test-research/` directory was created
- `data/ipc/test-research/` directory was created
- Container ran with the correct group folder

- [ ] **Step 3: Commit final state if any fixes needed**

```bash
git add -A
git commit -m "fix: address issues found in multi-group smoke test"
```
