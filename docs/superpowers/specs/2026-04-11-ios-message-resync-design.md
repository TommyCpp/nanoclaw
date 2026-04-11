# iOS Message Resync & Agent State Design

**Date:** 2026-04-11
**Scope:** iOS channel only

## Problem

Two observed failures in the iOS channel today:

1. **Message loss on disconnect race.** `ws.send()`'s callback fires when data is buffered into the socket, not when the client acknowledges. If the iOS client disconnects within milliseconds of a send, the data sits in the OS socket buffer and is lost. `pendingMessages` is only used when zero clients are connected at the moment of send, so this race bypasses it entirely. Concretely: at 02:37:37 today the host logged `iOS: message sent` for a reply to the "Google api" question; at 02:37:38 the client disconnected; the reply never reached the iPhone, and subsequent reconnects had nothing in `pendingMessages` to flush.

2. **No ground-truth agent state.** `setTyping(true/false)` fires at `runAgent` start/end boundaries, but the container can linger with `setTyping=true` long after the reply is delivered (waiting for next IPC message or idle-timeout sentinel). The iOS app has no reliable way to answer "is the agent actually working right now?"

Push-only delivery plus the typing-indicator-as-state model are both insufficient. A pull-based resync API solves both in one round trip.

## Non-Goals

- Fine-grained tool-use visibility (e.g. "running Bash"). Requires container-runner instrumentation and is deferred — see **Future Work**.
- Non-iOS channels. Discord has native history; Slack/WhatsApp/Telegram likewise. No resync needed for them.
- Host-side message archive for audit/search. Not needed today.

## Design

### Data model

New SQLite table in `src/db.ts`:

```sql
CREATE TABLE outbound_messages (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  chat_jid   TEXT NOT NULL,      -- e.g. 'ios:labor'
  seq        INTEGER NOT NULL,   -- per-chat_jid monotonic
  text       TEXT NOT NULL,
  created_at INTEGER NOT NULL,   -- unix ms
  UNIQUE(chat_jid, seq)
);
CREATE INDEX idx_outbound_chat_seq ON outbound_messages(chat_jid, seq);
```

**Invariant:** every outbound `sendMessage` call on the iOS channel inserts into this table **before** any WebSocket write. Seq is assigned as `COALESCE(MAX(seq), 0) + 1 WHERE chat_jid = ?` inside a transaction, so the first message on any chat gets `seq = 1`. If the host crashes after insert but before WebSocket delivery, the next resync still finds the message.

**Retention:** keep the most recent 500 rows per `chat_jid`. Prune on insert: after inserting, `DELETE FROM outbound_messages WHERE chat_jid = ? AND id NOT IN (SELECT id FROM outbound_messages WHERE chat_jid = ? ORDER BY seq DESC LIMIT 500)`.

### Wire protocol

**Outbound frames gain a `seq` field** (iOS channel only):

```json
{"type": "token", "text": "...", "chatId": "labor", "seq": 42}
{"type": "done", "chatId": "labor", "seq": 42}
```

Token and done frames for one logical message share the same seq.

**New inbound request — `sync`:**

```json
{"type": "sync", "chatId": "labor", "sinceSeq": 41}
```

`chatId` is optional; omitted = sync all known iOS chats. `sinceSeq` is the highest seq the client has already rendered for that chat.

**New outbound response — `sync_response`:**

```json
{
  "type": "sync_response",
  "chatId": "labor",
  "lastSeq": 47,
  "state": "idle",
  "messages": [
    {"seq": 42, "text": "...", "createdAt": 1744351057123},
    {"seq": 43, "text": "...", "createdAt": 1744351059456}
  ]
}
```

- `lastSeq`: the current max seq in the DB for that chat (regardless of `messages` length).
- `state`: see next section.
- `messages`: rows from the DB with `seq > sinceSeq`, ordered ascending. Empty if already up to date — sync then acts as a pure state-poll with no side effects.

If `sinceSeq === lastSeq`, messages is `[]` and the client just updates the state display. If `sinceSeq > lastSeq` (shouldn't happen, but a stale client after DB reset could cause it), the host treats it as `sinceSeq = lastSeq` — returns empty messages rather than an error.

The client should treat receiving a `sync_response` with `lastSeq < lastSeqByChatId[chatId]` as a signal that the host's DB was reset: drop local `lastSeq` to 0, re-render from whatever the server returned, and warn in the log.

### Agent state field

The `state` field answers "is this agent actually doing something right now?" using host-side signals only (no container instrumentation). Values:

| State | Definition |
|---|---|
| `idle` | No pending inbound messages for this chat, no live container process |
| `queued` | Messages pending in `group-queue` but container hasn't produced output yet |
| `running` | Container process alive **and** last stdout activity within the last 10 seconds |
| `stalled` | Container process alive but no stdout activity for more than 10 seconds |

**Why not use `setTyping` state?** Because `setTyping(true)` stays true until the container fully exits, which can be 30 minutes after the reply was delivered. `running` vs `stalled` uses `hadStreamingOutput` / timeout-reset timestamps from `container-runner.ts` — these are the same signals the hard-timeout watchdog already tracks, so they're ground truth.

State is computed on demand when a `sync` request arrives; no event stream needed.

### iOS client behavior

1. **Persist `lastSeqByChatId: [String: Int]` to UserDefaults.** Key: `ios_channel.lastSeq.<chatId>`.
2. **Update on every `done` frame:** `lastSeqByChatId[chatId] = max(current, frame.seq)`.
3. **Trigger sync when:**
   - App foreground / launch
   - WebSocket `auth_ok` received — send sync for every known chat
   - User pulls-to-refresh a chat
   - (Optional, v1.1) periodic 30s heartbeat sync for the currently-open chat, for state-display freshness
4. **Apply sync_response:**
   - Dedupe messages by seq (if any arrive via both push and sync)
   - Render in seq order
   - Update `lastSeqByChatId[chatId] = lastSeq`
   - Update the state indicator for that chat

### Host changes

| File | Change |
|---|---|
| `src/db.ts` | Add `outbound_messages` table; add `insertOutbound(chatJid, text): {seq}` (transactional seq assignment + prune to 500); add `getOutboundSince(chatJid, sinceSeq): OutboundMessage[]` |
| `src/channels/ios.ts` | `sendMessage`: insert into DB first, get seq, include seq in both token and done frames. Handle new `{type: 'sync'}` inbound frame. |
| `src/container-runner.ts` | Expose a `getActivityState(chatJid): 'idle' \| 'running' \| 'stalled'` helper that reads the live container process registry and its last-output timestamp. |
| `src/index.ts` | Add `getAgentState(chatJid): AgentState` that combines container state + group-queue pending count. |
| `src/types.ts` | Add `AgentState` type. **`Channel` interface is unchanged** — sync is iOS-specific. |

Scope is small and contained; no changes to `agent-runner` or `router.ts`.

### Rate limiting

Per WebSocket connection: `sync` requests limited to **10 per second**, using a simple token-bucket tracked on the `ws` instance (a field on the `WebSocket` object). Over-limit requests get `{type: 'error', message: 'rate limited', code: 'sync_rate_limit'}` and are dropped silently. No reconnect needed; iOS client should backoff.

### Back-compat

Old iOS clients that don't know about `seq`:

- They ignore the extra `seq` field in token/done frames (JSON ignored by the existing parser).
- They never send `sync`, so they simply continue relying on push + `pendingMessages`. No regression.

New iOS clients that connect to an old host:

- They send `sync`, old host replies with `{type: 'error', message: 'invalid JSON'}` or similar. Client treats any non-`sync_response` as "sync unsupported" and falls back to push-only.

Version negotiation not needed for v1 — feature detection via "did I get sync_response within 2s" is enough.

## Testing

Unit tests in `src/channels/ios.test.ts` (new file) and `src/db.test.ts`:

- **DB layer:** insertOutbound assigns monotonic seq per chat_jid; retention prunes to 500; getOutboundSince returns correct slice.
- **Channel layer:** sendMessage inserts into DB before WS write (mock ws to reject send — row should still exist); sync returns correct slice; sync on unknown chat returns empty; sync rate limit kicks in after 10 req/s.
- **State:** `getAgentState` returns `idle` with no container, `running` with fresh stdout timestamp, `stalled` with stale one, `queued` with queue length > 0 and no container.

Integration smoke test: start host, connect mock iOS client, send inbound, receive reply with seq=1, disconnect, reconnect with `sinceSeq=0`, verify reply is re-delivered via sync.

## Future work (out of scope for this spec)

- **Layer 2 tool visibility.** Instrument `container/agent-runner/src/index.ts runQuery()` to emit `tool_use` / `tool_result` events via a new `writeOutput` status. Host tracks the current tool per chat_jid, exposes a new `state: 'tool'` value plus an optional `currentTool: string` field on `sync_response`. Adding optional fields is backward-compatible for the v1 client, which will simply ignore them.
- **Push delta frames for active viewers.** For clients that are currently looking at a chat, push a `{type: 'state', state: 'running', chatId}` frame whenever state changes, so the UI updates without polling. Uses the same state source as sync.
- **Non-iOS channel resync.** Not needed today.
