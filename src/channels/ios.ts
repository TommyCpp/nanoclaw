import { createServer as createHttpServer } from 'http';
import { createServer as createHttpsServer } from 'https';
import { readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { randomUUID } from 'crypto';
import { WebSocketServer, WebSocket } from 'ws';

import { ASSISTANT_NAME, TRIGGER_PATTERN } from '../config.js';
import {
  setRegisteredGroup,
  getAllTasks,
  insertOutbound,
  getOutboundSince,
  getLastOutboundSeq,
} from '../db.js';
import { readEnvFile } from '../env.js';
import { isValidGroupFolder } from '../group-folder.js';
import { logger } from '../logger.js';
import { registerChannel, ChannelOpts } from './registry.js';
import {
  AgentState,
  Channel,
  OnChatMetadata,
  OnInboundMessage,
  RegisteredGroup,
} from '../types.js';

const DEFAULT_CHAT_ID = 'main';

// Rate limit sync requests per connection. Protects the DB from a runaway
// client while still allowing normal pull-to-refresh and foreground bursts.
const SYNC_RATE_LIMIT_MAX = 10;
const SYNC_RATE_LIMIT_WINDOW_MS = 1_000;

interface SyncRateState {
  windowStart: number;
  count: number;
}

/** Per-WebSocket rate-limit bucket. Key attached to each ws as a hidden field. */
const SYNC_RATE_KEY = Symbol('nanoclawSyncRate');

function checkSyncRateLimit(ws: WebSocket): boolean {
  const wsAny = ws as unknown as { [SYNC_RATE_KEY]?: SyncRateState };
  const now = Date.now();
  const state = wsAny[SYNC_RATE_KEY];
  if (!state || now - state.windowStart > SYNC_RATE_LIMIT_WINDOW_MS) {
    wsAny[SYNC_RATE_KEY] = { windowStart: now, count: 1 };
    return true;
  }
  if (state.count >= SYNC_RATE_LIMIT_MAX) {
    return false;
  }
  state.count += 1;
  return true;
}

function iosJid(chatId: string): string {
  return `ios:${chatId}`;
}

function iosFolder(chatId: string): string {
  return `ios-${chatId}`;
}

interface IosChannelOpts {
  onMessage: OnInboundMessage;
  onChatMetadata: OnChatMetadata;
  registeredGroups: () => Record<string, RegisteredGroup>;
  /** Optional agent state lookup; used to populate sync_response.state.
   *  Defaults to 'idle' when not provided (e.g. in unit tests). */
  getAgentState?: (chatJid: string) => AgentState;
  secret: string;
  port: number;
}

export class IosChannel implements Channel {
  name = 'ios';

  private opts: IosChannelOpts;
  private wss: WebSocketServer | null = null;
  private clients = new Set<WebSocket>();
  private connected = false;

  constructor(opts: IosChannelOpts) {
    this.opts = opts;
  }

  async connect(): Promise<void> {
    this.ensureChannelRegistered(DEFAULT_CHAT_ID, true);

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

            // Message catch-up is now handled by the client via sync, not
            // by in-memory buffering. The client issues one sync per chat
            // after receiving auth_ok and ingests any missed outbound
            // messages from the DB archive (outbound_messages table).
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

        if (msg.type === 'list_tasks') {
          const tasks = getAllTasks();
          ws.send(JSON.stringify({ type: 'tasks', tasks }));
          return;
        }

        // Pull-based resync: client asks "give me everything I missed for
        // <chatId> since seq <sinceSeq>, plus the current agent state".
        //
        // Response shape:
        //   { type: 'sync_response', chatId, lastSeq, state, messages: [...] }
        //
        // If sinceSeq >= lastSeq, messages will be []. That makes sync a
        // generic state-poll with no side effects.
        if (msg.type === 'sync') {
          if (!checkSyncRateLimit(ws)) {
            ws.send(
              JSON.stringify({
                type: 'error',
                code: 'sync_rate_limit',
                message: 'sync rate limit exceeded',
              }),
            );
            return;
          }
          const chatId =
            typeof msg.chatId === 'string' && msg.chatId.trim()
              ? msg.chatId.trim()
              : DEFAULT_CHAT_ID;
          const sinceSeq =
            typeof msg.sinceSeq === 'number' && Number.isFinite(msg.sinceSeq)
              ? Math.max(0, Math.floor(msg.sinceSeq))
              : 0;
          const jid = iosJid(chatId);
          const lastSeq = getLastOutboundSeq(jid);
          const messages =
            sinceSeq >= lastSeq ? [] : getOutboundSince(jid, sinceSeq);
          const state: AgentState = this.opts.getAgentState?.(jid) ?? 'idle';
          ws.send(
            JSON.stringify({
              type: 'sync_response',
              chatId,
              lastSeq,
              state,
              messages: messages.map((m) => ({
                seq: m.seq,
                text: m.text,
                createdAt: m.created_at,
              })),
            }),
          );
          return;
        }

        // Create a new channel
        if (msg.type === 'create_channel') {
          const chatId =
            typeof msg.chatId === 'string' ? msg.chatId.trim() : '';
          const name = typeof msg.name === 'string' ? msg.name.trim() : chatId;
          if (!chatId) {
            ws.send(
              JSON.stringify({ type: 'error', message: 'chatId required' }),
            );
            return;
          }
          const folder = iosFolder(chatId);
          if (!isValidGroupFolder(folder)) {
            ws.send(
              JSON.stringify({ type: 'error', message: 'invalid chatId' }),
            );
            return;
          }
          this.ensureChannelRegistered(chatId, false, name);
          ws.send(
            JSON.stringify({
              type: 'channel_created',
              chatId,
              name,
              folder,
            }),
          );
          logger.info({ chatId }, 'iOS: channel created');
          return;
        }

        // List all iOS channels
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

        if (msg.type !== 'message' || typeof msg.text !== 'string') return;

        const chatId =
          typeof msg.chatId === 'string' && msg.chatId.trim()
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

  async sendMessage(jid: string, text: string): Promise<void> {
    const chatId = jid.replace(/^ios:/, '');

    // Archive first, then push. The DB is the single source of truth for
    // "what messages does this chat have"; WebSocket push is pure cache
    // invalidation / live delivery. If push fails (disconnected client,
    // stale socket, send/disconnect race, host crash mid-send) the DB
    // record is already there and the client's next sync will pick it up.
    const { seq } = insertOutbound(jid, text);

    const token = JSON.stringify({ type: 'token', text, chatId, seq });
    const done = JSON.stringify({ type: 'done', chatId, seq });
    const connected = [...this.clients].filter(
      (ws) => ws.readyState === WebSocket.OPEN,
    );
    if (connected.length === 0) {
      // No live clients → nothing to push. The message is in the DB; when
      // a client reconnects, its sync will deliver this.
      logger.info(
        { chatId, seq, length: text.length },
        'iOS: no client connected, relying on sync for delivery',
      );
      return;
    }
    for (const ws of connected) {
      try {
        await new Promise<void>((resolve, reject) => {
          ws.send(token, (err) => (err ? reject(err) : resolve()));
        });
        await new Promise<void>((resolve, reject) => {
          ws.send(done, (err) => (err ? reject(err) : resolve()));
        });
      } catch (err) {
        // Push failed mid-send. The DB still has the row, so the client
        // will recover it on next sync. Just drop the stale socket.
        logger.warn(
          { chatId, seq, err },
          'iOS: send failed, dropping stale client (sync will recover)',
        );
        this.clients.delete(ws);
        return;
      }
    }
    logger.info(
      { clients: connected.length, chatId, seq, length: text.length },
      'iOS: message sent',
    );
  }

  async setTyping(jid: string, isTyping: boolean): Promise<void> {
    const chatId = jid.replace(/^ios:/, '');
    const payload = JSON.stringify({ type: 'typing', isTyping, chatId });
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

  private ensureChannelRegistered(
    chatId: string,
    isMain: boolean,
    displayName?: string,
  ): void {
    const jid = iosJid(chatId);
    const groups = this.opts.registeredGroups();
    if (groups[jid]) return;

    const folder = iosFolder(chatId);
    const group: RegisteredGroup = {
      name: displayName || chatId,
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
    getAgentState: opts.getAgentState,
    secret,
    port,
  });
});
