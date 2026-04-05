import { createServer, IncomingMessage, ServerResponse } from 'http';

import { setRegisteredGroup } from '../db.js';
import { readEnvFile } from '../env.js';
import { isValidGroupFolder } from '../group-folder.js';
import { logger } from '../logger.js';
import { registerChannel, ChannelOpts } from './registry.js';
import {
  Channel,
  OnChatMetadata,
  OnInboundMessage,
  RegisteredGroup,
} from '../types.js';

const DEFAULT_CHAT_ID = 'local';

function testJid(chatId: string): string {
  return `test:${chatId}`;
}

function testFolder(chatId: string): string {
  return `test-${chatId}`;
}

interface TestChannelOpts {
  onMessage: OnInboundMessage;
  onChatMetadata: OnChatMetadata;
  registeredGroups: () => Record<string, RegisteredGroup>;
  clearSession?: (folder: string) => void;
  port: number;
}

export class TestChannel implements Channel {
  name = 'test';

  private opts: TestChannelOpts;
  private buffers = new Map<string, string[]>();
  private connected = false;

  constructor(opts: TestChannelOpts) {
    this.opts = opts;
  }

  async connect(): Promise<void> {
    this.ensureChannelRegistered(DEFAULT_CHAT_ID, true);

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
      isMain,
    };

    setRegisteredGroup(jid, group);
    groups[jid] = group;
    logger.info({ jid, folder }, 'Test channel: registered group');
  }

  private handleRequest(req: IncomingMessage, res: ServerResponse): void {
    const url = req.url ?? '/';
    const method = req.method ?? 'GET';

    // POST /channels — create a new channel
    if (method === 'POST' && url === '/channels') {
      let body = '';
      req.on('data', (chunk) => {
        body += chunk;
      });
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
        res.end(
          JSON.stringify({ ok: true, jid, folder, name: name || chatId }),
        );
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

    // POST /message — send a message into the agent
    if (method === 'POST' && url === '/message') {
      let body = '';
      req.on('data', (chunk) => {
        body += chunk;
      });
      req.on('end', () => {
        let text: string;
        let chatId: string;
        try {
          const parsed = JSON.parse(body);
          if (typeof parsed.text !== 'string' || !parsed.text.trim()) {
            res.writeHead(400, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'text required' }));
            return;
          }
          text = parsed.text.trim();
          chatId =
            typeof parsed.chatId === 'string' && parsed.chatId.trim()
              ? parsed.chatId.trim()
              : DEFAULT_CHAT_ID;
        } catch {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'invalid JSON' }));
          return;
        }

        const jid = testJid(chatId);

        // Auto-register channel on first message
        const groups = this.opts.registeredGroups();
        if (!groups[jid]) {
          this.ensureChannelRegistered(chatId, false);
        }

        const msgId = `test-${Date.now()}`;
        this.opts.onChatMetadata(
          jid,
          new Date().toISOString(),
          `Test ${chatId}`,
          'test',
          false,
        );
        this.opts.onMessage(jid, {
          id: msgId,
          chat_jid: jid,
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

    // GET /messages — drain response buffer (optional ?chatId= query param)
    if (
      method === 'GET' &&
      (url === '/messages' || url?.startsWith('/messages?'))
    ) {
      const urlObj = new URL(url, `http://${req.headers.host}`);
      const chatId = urlObj.searchParams.get('chatId') ?? DEFAULT_CHAT_ID;
      const buf = this.buffers.get(chatId) ?? [];
      const messages = buf.splice(0);
      if (buf.length === 0) this.buffers.delete(chatId);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ messages }));
      return;
    }

    // DELETE /session — clear session (optional ?chatId= query param)
    if (
      method === 'DELETE' &&
      (url === '/session' || url?.startsWith('/session?'))
    ) {
      const urlObj = new URL(url, `http://${req.headers.host}`);
      const chatId = urlObj.searchParams.get('chatId') ?? DEFAULT_CHAT_ID;
      this.opts.clearSession?.(testFolder(chatId));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
      return;
    }

    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'not found' }));
  }

  async sendMessage(jid: string, text: string): Promise<void> {
    const chatId = jid.replace(/^test:/, '');
    const buf = this.buffers.get(chatId) ?? [];
    buf.push(text);
    this.buffers.set(chatId, buf);
    logger.debug(
      { jid, length: text.length },
      'Test channel: buffered outbound message',
    );
  }

  isConnected(): boolean {
    return this.connected;
  }

  ownsJid(jid: string): boolean {
    return jid.startsWith('test:');
  }

  async disconnect(): Promise<void> {
    this.connected = false;
  }
}

registerChannel('test', (opts: ChannelOpts) => {
  const envVars = readEnvFile(['TEST_CHANNEL_ENABLED', 'TEST_CHANNEL_PORT']);
  const enabled =
    (process.env.TEST_CHANNEL_ENABLED || envVars.TEST_CHANNEL_ENABLED) ===
    'true';
  if (!enabled) return null;

  const port = parseInt(
    process.env.TEST_CHANNEL_PORT || envVars.TEST_CHANNEL_PORT || '8765',
    10,
  );

  return new TestChannel({
    onMessage: opts.onMessage,
    onChatMetadata: opts.onChatMetadata,
    registeredGroups: opts.registeredGroups,
    clearSession: opts.clearSession,
    port,
  });
});
