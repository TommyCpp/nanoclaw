import { createServer as createHttpServer } from 'http';
import { createServer as createHttpsServer } from 'https';
import { readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { randomUUID } from 'crypto';
import { WebSocketServer, WebSocket } from 'ws';

import { ASSISTANT_NAME, TRIGGER_PATTERN } from '../config.js';
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

/** Single persistent group — all iOS conversations share one history + memory */
const IOS_JID = 'ios:main';
const IOS_FOLDER = 'ios_main';

interface IosChannelOpts {
  onMessage: OnInboundMessage;
  onChatMetadata: OnChatMetadata;
  registeredGroups: () => Record<string, RegisteredGroup>;
  secret: string;
  port: number;
}

export class IosChannel implements Channel {
  name = 'ios';

  private opts: IosChannelOpts;
  private wss: WebSocketServer | null = null;
  private clients = new Set<WebSocket>();
  /** Messages buffered while no client is connected */
  private pendingMessages: string[] = [];
  private connected = false;

  constructor(opts: IosChannelOpts) {
    this.opts = opts;
  }

  async connect(): Promise<void> {
    this.ensureGroupRegistered();

    const tlsCert = join(process.cwd(), 'data', 'tls', 'server.crt');
    const tlsKey = join(process.cwd(), 'data', 'tls', 'server.key');
    const useTls = existsSync(tlsCert) && existsSync(tlsKey);

    const requestHandler = (_req: any, res: any) => {
      res.writeHead(200, { 'Content-Type': 'text/plain' });
      res.end('NanoClaw iOS channel OK\n');
    };

    const server = useTls
      ? createHttpsServer(
          { cert: readFileSync(tlsCert), key: readFileSync(tlsKey) },
          requestHandler,
        )
      : createHttpServer(requestHandler);

    this.wss = new WebSocketServer({ server });

    this.wss.on('error', (err) => logger.error({ err }, 'iOS: wss error'));

    this.wss.on('connection', (ws, req) => {
      let authenticated = false;

      ws.on('message', (raw) => {
        let msg: any;
        try {
          msg = JSON.parse(raw.toString());
        } catch {
          ws.send(JSON.stringify({ type: 'error', message: 'invalid JSON' }));
          return;
        }

        // Auth handshake — must be first frame
        if (!authenticated) {
          if (msg.auth === this.opts.secret) {
            authenticated = true;
            this.clients.add(ws);
            ws.send(JSON.stringify({ type: 'auth_ok' }));
            logger.info(
              { ip: (req.socket as any).remoteAddress },
              'iOS client connected',
            );
          } else {
            ws.send(JSON.stringify({ type: 'error', message: 'unauthorized' }));
            ws.close();
          }
          return;
        }

        // Heartbeat
        if (msg.type === 'ping') {
          ws.send(JSON.stringify({ type: 'pong' }));
          return;
        }

        if (msg.type !== 'message' || typeof msg.text !== 'string') return;

        const msgId = typeof msg.id === 'string' ? msg.id : randomUUID();
        const content = msg.text.trim();
        if (!content) return;

        // Prepend trigger so the message loop picks it up
        const routed = TRIGGER_PATTERN.test(content)
          ? content
          : `@${ASSISTANT_NAME} ${content}`;

        this.opts.onChatMetadata(
          IOS_JID,
          new Date().toISOString(),
          'NanoClaw iOS',
          'ios',
          false,
        );
        this.opts.onMessage(IOS_JID, {
          id: msgId,
          chat_jid: IOS_JID,
          sender: 'ios-user',
          sender_name: 'iOS',
          content: routed,
          timestamp: new Date().toISOString(),
          is_from_me: false,
        });

        logger.info({ msgId }, 'iOS: inbound message');
      });

      ws.on('close', () => {
        this.clients.delete(ws);
        logger.info('iOS client disconnected');
      });

      ws.on('error', (err) => {
        logger.error({ err }, 'iOS WebSocket error');
        this.clients.delete(ws);
      });
    });

    await new Promise<void>((resolve) => {
      server.listen(this.opts.port, '0.0.0.0', () => {
        this.connected = true;
        const scheme = useTls ? 'wss' : 'ws';
        logger.info(
          { port: this.opts.port, tls: useTls },
          'iOS WebSocket channel listening',
        );
        console.log(
          `\n  iOS channel: ${scheme}://localhost:${this.opts.port}${useTls ? ' (TLS)' : ''}\n`,
        );
        resolve();
      });
    });
  }

  async sendMessage(_jid: string, text: string): Promise<void> {
    const token = JSON.stringify({ type: 'token', text });
    const done = JSON.stringify({ type: 'done' });
    for (const ws of this.clients) {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(token);
        ws.send(done);
      }
    }
    logger.info(
      { clients: this.clients.size, length: text.length },
      'iOS: message sent',
    );
  }

  async setTyping(_jid: string, isTyping: boolean): Promise<void> {
    const payload = JSON.stringify({ type: 'typing', isTyping });
    for (const ws of this.clients) {
      if (ws.readyState === WebSocket.OPEN) ws.send(payload);
    }
  }

  isConnected(): boolean {
    return this.connected;
  }

  ownsJid(jid: string): boolean {
    return jid.startsWith('ios:');
  }

  async disconnect(): Promise<void> {
    for (const ws of this.clients) ws.close();
    this.clients.clear();
    this.wss?.close();
    this.wss = null;
    this.connected = false;
    logger.info('iOS WebSocket channel disconnected');
  }

  private ensureGroupRegistered(): void {
    const groups = this.opts.registeredGroups();
    if (groups[IOS_JID]) return;

    const group = {
      name: 'NanoClaw iOS',
      folder: IOS_FOLDER,
      trigger: `@${ASSISTANT_NAME}`,
      added_at: new Date().toISOString(),
      requiresTrigger: false,
    };

    try {
      setRegisteredGroup(IOS_JID, group);
      // Also update in-memory cache immediately
      groups[IOS_JID] = group;
      logger.info({ jid: IOS_JID }, 'iOS: registered ios:main group');
    } catch (err) {
      logger.error({ err }, 'iOS: failed to register ios:main group');
    }
  }
}

registerChannel('ios', (opts: ChannelOpts) => {
  const envVars = readEnvFile(['IOS_CHANNEL_SECRET', 'IOS_CHANNEL_PORT']);
  const secret =
    process.env.IOS_CHANNEL_SECRET || envVars.IOS_CHANNEL_SECRET || '';
  if (!secret) {
    logger.warn('iOS: IOS_CHANNEL_SECRET not set — channel disabled');
    return null;
  }
  const port = parseInt(
    process.env.IOS_CHANNEL_PORT || envVars.IOS_CHANNEL_PORT || '8080',
    10,
  );
  return new IosChannel({
    onMessage: opts.onMessage,
    onChatMetadata: opts.onChatMetadata,
    registeredGroups: opts.registeredGroups,
    secret,
    port,
  });
});
