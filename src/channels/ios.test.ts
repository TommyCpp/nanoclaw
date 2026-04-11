import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { WebSocket } from 'ws';

import { _initTestDatabase, getLastOutboundSeq, insertOutbound } from '../db.js';

// --- Mocks ---
vi.mock('./registry.js', () => ({ registerChannel: vi.fn() }));
vi.mock('../env.js', () => ({ readEnvFile: vi.fn(() => ({})) }));
vi.mock('../config.js', () => ({
  ASSISTANT_NAME: 'Andy',
  TRIGGER_PATTERN: /^@Andy\b/i,
}));
vi.mock('../logger.js', () => ({
  logger: {
    debug: vi.fn(),
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn(),
  },
}));

import { IosChannel } from './ios.js';

const TEST_SECRET = 'test-secret';
const BASE_PORT = 18090;
let nextPort = BASE_PORT;

/** Allocate a unique port per test to avoid EADDRINUSE on parallel runs. */
function allocatePort(): number {
  return nextPort++;
}

interface Frame {
  type: string;
  [k: string]: unknown;
}

/**
 * Open a ws client, perform auth handshake, and return an object that lets
 * the test drive the connection. Resolves after receiving `auth_ok`.
 */
async function authenticatedClient(
  port: number,
): Promise<{
  ws: WebSocket;
  receive: (pred: (f: Frame) => boolean, timeoutMs?: number) => Promise<Frame>;
  send: (msg: object) => void;
  close: () => void;
}> {
  const ws = new WebSocket(`ws://localhost:${port}`);
  const buffer: Frame[] = [];
  const pending: Array<{
    pred: (f: Frame) => boolean;
    resolve: (f: Frame) => void;
    reject: (e: Error) => void;
    timer: NodeJS.Timeout;
  }> = [];

  ws.on('message', (data) => {
    try {
      const frame = JSON.parse(data.toString()) as Frame;
      buffer.push(frame);
      for (let i = pending.length - 1; i >= 0; i--) {
        const entry = pending[i];
        if (entry.pred(frame)) {
          clearTimeout(entry.timer);
          pending.splice(i, 1);
          entry.resolve(frame);
        }
      }
    } catch {
      /* ignore parse errors in test harness */
    }
  });

  await new Promise<void>((resolve, reject) => {
    ws.once('open', () => resolve());
    ws.once('error', reject);
  });
  ws.send(JSON.stringify({ auth: TEST_SECRET }));

  function receive(
    pred: (f: Frame) => boolean,
    timeoutMs = 1_000,
  ): Promise<Frame> {
    // Check buffer first
    for (let i = 0; i < buffer.length; i++) {
      if (pred(buffer[i])) {
        const [frame] = buffer.splice(i, 1);
        return Promise.resolve(frame);
      }
    }
    return new Promise<Frame>((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error('receive timeout'));
      }, timeoutMs);
      pending.push({ pred, resolve, reject, timer });
    });
  }

  // Wait for auth_ok
  await receive((f) => f.type === 'auth_ok');

  return {
    ws,
    receive,
    send: (msg: object) => ws.send(JSON.stringify(msg)),
    close: () => ws.close(),
  };
}

describe('IosChannel sync + seq', () => {
  let channel: IosChannel;
  let port: number;

  beforeEach(async () => {
    _initTestDatabase();
    port = allocatePort();
    channel = new IosChannel({
      onMessage: vi.fn(),
      onChatMetadata: vi.fn(),
      registeredGroups: () => ({}),
      getAgentState: () => 'idle',
      secret: TEST_SECRET,
      port,
    });
    await channel.connect();
  });

  afterEach(async () => {
    await channel.disconnect();
  });

  it('assigns seq to outbound frames and archives them in the DB', async () => {
    const client = await authenticatedClient(port);
    try {
      const sendPromise = channel.sendMessage('ios:main', 'hello world');

      const token = await client.receive((f) => f.type === 'token');
      const done = await client.receive((f) => f.type === 'done');
      await sendPromise;

      expect(token.seq).toBe(1);
      expect(token.text).toBe('hello world');
      expect(token.chatId).toBe('main');
      expect(done.seq).toBe(1);
      expect(getLastOutboundSeq('ios:main')).toBe(1);
    } finally {
      client.close();
    }
  });

  it('sync returns empty messages and current state when client is up to date', async () => {
    const client = await authenticatedClient(port);
    try {
      client.send({ type: 'sync', chatId: 'main', sinceSeq: 0 });
      const resp = await client.receive((f) => f.type === 'sync_response');

      expect(resp.chatId).toBe('main');
      expect(resp.lastSeq).toBe(0);
      expect(resp.state).toBe('idle');
      expect(resp.messages).toEqual([]);
    } finally {
      client.close();
    }
  });

  it('sync delivers messages missed while the client was disconnected', async () => {
    // Pre-seed DB as if a prior send happened
    insertOutbound('ios:main', 'lost message 1');
    insertOutbound('ios:main', 'lost message 2');

    const client = await authenticatedClient(port);
    try {
      client.send({ type: 'sync', chatId: 'main', sinceSeq: 0 });
      const resp = await client.receive((f) => f.type === 'sync_response');

      expect(resp.lastSeq).toBe(2);
      const messages = resp.messages as Array<{ seq: number; text: string }>;
      expect(messages.length).toBe(2);
      expect(messages[0].seq).toBe(1);
      expect(messages[0].text).toBe('lost message 1');
      expect(messages[1].seq).toBe(2);
      expect(messages[1].text).toBe('lost message 2');
    } finally {
      client.close();
    }
  });

  it('sync returns only messages newer than sinceSeq', async () => {
    insertOutbound('ios:main', 'old');
    insertOutbound('ios:main', 'new');

    const client = await authenticatedClient(port);
    try {
      client.send({ type: 'sync', chatId: 'main', sinceSeq: 1 });
      const resp = await client.receive((f) => f.type === 'sync_response');

      const messages = resp.messages as Array<{ seq: number; text: string }>;
      expect(messages.length).toBe(1);
      expect(messages[0].text).toBe('new');
    } finally {
      client.close();
    }
  });

  it('sync returns empty when sinceSeq > lastSeq (stale client, defensive)', async () => {
    insertOutbound('ios:main', 'one');

    const client = await authenticatedClient(port);
    try {
      client.send({ type: 'sync', chatId: 'main', sinceSeq: 99 });
      const resp = await client.receive((f) => f.type === 'sync_response');

      expect(resp.lastSeq).toBe(1);
      expect(resp.messages).toEqual([]);
    } finally {
      client.close();
    }
  });

  it('sync respects per-connection rate limit', async () => {
    const client = await authenticatedClient(port);
    try {
      // Send 11 back-to-back sync requests
      for (let i = 0; i < 11; i++) {
        client.send({ type: 'sync', chatId: 'main', sinceSeq: 0 });
      }

      // First 10 should succeed, 11th should be rate-limited
      const responses: Frame[] = [];
      for (let i = 0; i < 10; i++) {
        responses.push(await client.receive((f) => f.type === 'sync_response'));
      }
      const errFrame = await client.receive(
        (f) => f.type === 'error' && f.code === 'sync_rate_limit',
      );
      expect(errFrame.code).toBe('sync_rate_limit');
      expect(responses.length).toBe(10);
    } finally {
      client.close();
    }
  });

  it('sendMessage archives to DB even when no client is connected', async () => {
    // Don't open a client this time
    await channel.sendMessage('ios:main', 'buffered message');

    expect(getLastOutboundSeq('ios:main')).toBe(1);
  });

  it('scopes sync by chatId', async () => {
    insertOutbound('ios:main', 'main-only');
    insertOutbound('ios:labor', 'labor-only');

    const client = await authenticatedClient(port);
    try {
      client.send({ type: 'sync', chatId: 'labor', sinceSeq: 0 });
      const resp = await client.receive((f) => f.type === 'sync_response');

      const messages = resp.messages as Array<{ text: string }>;
      expect(messages.length).toBe(1);
      expect(messages[0].text).toBe('labor-only');
      expect(resp.chatId).toBe('labor');
    } finally {
      client.close();
    }
  });

  it('forwards agent state from getAgentState callback', async () => {
    // Swap in a channel that reports 'running'
    await channel.disconnect();
    port = allocatePort();
    channel = new IosChannel({
      onMessage: vi.fn(),
      onChatMetadata: vi.fn(),
      registeredGroups: () => ({}),
      getAgentState: () => 'running',
      secret: TEST_SECRET,
      port,
    });
    await channel.connect();

    const client = await authenticatedClient(port);
    try {
      client.send({ type: 'sync', chatId: 'main', sinceSeq: 0 });
      const resp = await client.receive((f) => f.type === 'sync_response');
      expect(resp.state).toBe('running');
    } finally {
      client.close();
    }
  });
});
