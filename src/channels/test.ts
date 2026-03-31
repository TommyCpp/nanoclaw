import { createServer, IncomingMessage, ServerResponse } from 'http';

import { setRegisteredGroup } from '../db.js';
import { readEnvFile } from '../env.js';
import { logger } from '../logger.js';
import { registerChannel, ChannelOpts } from './registry.js';
import {
  Channel,
  OnChatMetadata,
  OnInboundMessage,
  RegisteredGroup,
} from '../types.js';

const TEST_JID = 'test:local';
const TEST_FOLDER = 'test-local';

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
    const groups = this.opts.registeredGroups();

    const group: RegisteredGroup = {
      name: 'Test',
      folder: TEST_FOLDER,
      trigger: '@test',
      added_at: new Date().toISOString(),
      requiresTrigger: false,
      isMain: true,
    };

    try {
      setRegisteredGroup(TEST_JID, group);
      groups[TEST_JID] = group;
      logger.info(
        { jid: TEST_JID },
        'Test channel: registered test:local group',
      );
    } catch (err) {
      logger.error({ err }, 'Test channel: failed to register group');
    }
  }

  private handleRequest(req: IncomingMessage, res: ServerResponse): void {
    const url = req.url ?? '/';
    const method = req.method ?? 'GET';

    // POST /message — send a message into the agent
    if (method === 'POST' && url === '/message') {
      let body = '';
      req.on('data', (chunk) => {
        body += chunk;
      });
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
        this.opts.onChatMetadata(
          TEST_JID,
          new Date().toISOString(),
          'Test',
          'test',
          false,
        );
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
    logger.debug(
      { length: text.length },
      'Test channel: buffered outbound message',
    );
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
