import { execFileSync } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';

import { CC_SESSION_BASE, DATA_DIR } from './config.js';
import { logger } from './logger.js';

interface CcSession {
  directory: string;
  tmuxSession: string;
  url: string;
  startedBy: string;
  chatJid: string;
  startedAt: string;
}

const sessions = new Map<string, CcSession>();

const TMUX_BIN = '/opt/homebrew/bin/tmux';
const CLAUDE_BIN = '/Users/zhongyang/.local/bin/claude';

// Match session-level URLs (from /remote-control handoff)
const SESSION_URL_REGEX = /https:\/\/claude\.ai\/code\/session_\S+/;
// Fallback: match environment-level URLs
const ENV_URL_REGEX = /https:\/\/claude\.ai\/code\?environment=\S+/;
// Combined: prefer session URL, fall back to environment URL
const URL_REGEX = /https:\/\/claude\.ai\/code\S+/;

const CLAUDE_READY_TIMEOUT_MS = 30_000;
const URL_TIMEOUT_MS = 30_000;
const POLL_MS = 300;
const STATE_FILE = path.join(DATA_DIR, 'cc-sessions.json');

// Pattern that indicates claude interactive session is ready for input
const READY_PATTERN = /^❯\s*$/m;

function saveState(): void {
  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(
    STATE_FILE,
    JSON.stringify(Array.from(sessions.values()), null, 2),
  );
}

function sanitizeSessionName(dir: string): string {
  const base = path.basename(dir);
  return `cc-${base
    .replace(/[^a-zA-Z0-9-]/g, '-')
    .toLowerCase()
    .slice(0, 50)}`;
}

function tmuxHasSession(name: string): boolean {
  try {
    execFileSync(TMUX_BIN, ['has-session', '-t', name], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

function tmuxCapture(name: string): string {
  try {
    return execFileSync(
      TMUX_BIN,
      ['capture-pane', '-p', '-t', name, '-S', '-50'],
      {
        encoding: 'utf-8',
        timeout: 5000,
      },
    );
  } catch {
    return '';
  }
}

/**
 * Validate that a directory path is under ~/Dev.
 * Returns the resolved absolute path or null if invalid.
 */
export function validateDirectory(dir: string): string | null {
  // Expand ~ to home directory
  const expanded = dir.startsWith('~/')
    ? path.join(os.homedir(), dir.slice(2))
    : dir;

  // Must be absolute after expansion
  if (!path.isAbsolute(expanded)) return null;

  // Directory must exist
  let resolved: string;
  try {
    resolved = fs.realpathSync(expanded);
  } catch {
    // realpathSync fails if path doesn't exist — check without symlink resolution
    if (!fs.existsSync(expanded)) return null;
    resolved = path.resolve(expanded);
  }

  // Must be under ~/Dev (after resolving symlinks to prevent escapes)
  const base = fs.realpathSync(CC_SESSION_BASE);
  if (!resolved.startsWith(base + '/') && resolved !== base) {
    return null;
  }

  return resolved;
}

export async function startCcSession(
  directory: string,
  sender: string,
  chatJid: string,
): Promise<{ ok: true; url: string } | { ok: false; error: string }> {
  const resolved = validateDirectory(directory);
  if (!resolved) {
    return {
      ok: false,
      error: `Directory must be under ~/Dev. Got: ${directory}`,
    };
  }

  // Check for existing session
  const existing = sessions.get(resolved);
  if (existing && tmuxHasSession(existing.tmuxSession)) {
    // Tmux session alive — reconnect by sending /remote-control again
    return reconnectCcSession(existing.tmuxSession, resolved!, sender, chatJid);
  }
  // Clean up dead session
  if (existing) {
    sessions.delete(resolved);
  }

  // Derive unique tmux session name
  let tmuxName = sanitizeSessionName(resolved);
  if (tmuxHasSession(tmuxName)) {
    // Name collision from a different directory — append hash
    const hash = Math.random().toString(36).slice(2, 6);
    tmuxName = `${tmuxName}-${hash}`;
  }

  // Step 1: Start interactive claude session in tmux
  try {
    execFileSync(
      TMUX_BIN,
      [
        'new-session',
        '-d',
        '-s',
        tmuxName,
        '-c',
        resolved,
        '-x',
        '220',
        '-y',
        '50',
        '--',
        CLAUDE_BIN,
        '--permission-mode',
        'bypassPermissions',
        '--dangerously-skip-permissions',
        '--name',
        `CC: ${path.basename(resolved)}`,
      ],
      { stdio: 'ignore', timeout: 10_000 },
    );
  } catch (err: any) {
    return { ok: false, error: `Failed to start tmux session: ${err.message}` };
  }

  // Step 2: Wait for claude to be ready, then send /remote-control
  const readyResult = await waitForReady(tmuxName);
  if (!readyResult.ok) {
    try {
      execFileSync(TMUX_BIN, ['kill-session', '-t', tmuxName], {
        stdio: 'ignore',
      });
    } catch {
      /* already dead */
    }
    return readyResult;
  }

  // Step 3: Send /remote-control to hand off the session
  try {
    execFileSync(
      TMUX_BIN,
      ['send-keys', '-t', tmuxName, '/remote-control', 'Enter'],
      { stdio: 'ignore', timeout: 5000 },
    );
  } catch (err: any) {
    return {
      ok: false,
      error: `Failed to send /remote-control: ${err.message}`,
    };
  }

  logger.info(
    { tmuxName, directory: resolved },
    'CC session started, waiting for remote-control URL',
  );

  // Step 4: Poll for the session URL
  return pollForUrl(tmuxName, resolved!, sender, chatJid, true);
}

/**
 * Wait for the claude interactive session to be ready (showing the ❯ prompt).
 */
function waitForReady(
  tmuxName: string,
): Promise<{ ok: true } | { ok: false; error: string }> {
  return new Promise((resolve) => {
    const startTime = Date.now();

    const poll = () => {
      if (!tmuxHasSession(tmuxName)) {
        resolve({ ok: false, error: 'Claude session exited before ready' });
        return;
      }

      const content = tmuxCapture(tmuxName);
      if (READY_PATTERN.test(content)) {
        resolve({ ok: true });
        return;
      }

      if (Date.now() - startTime >= CLAUDE_READY_TIMEOUT_MS) {
        resolve({
          ok: false,
          error: 'Timed out waiting for Claude session to be ready',
        });
        return;
      }

      setTimeout(poll, POLL_MS);
    };

    poll();
  });
}

/**
 * Reconnect: send /remote-control in an existing tmux session to get a fresh URL.
 * Uses a marker to distinguish new URL from old scrollback.
 */
async function reconnectCcSession(
  tmuxName: string,
  resolved: string,
  sender: string,
  chatJid: string,
): Promise<{ ok: true; url: string } | { ok: false; error: string }> {
  const marker = `__CC_RECONNECT_${Date.now()}__`;

  // Check if remote-control is already active by looking for existing session URL
  const content = tmuxCapture(tmuxName);
  const existingMatch = content.match(SESSION_URL_REGEX);
  if (existingMatch && content.includes('Remote Control active')) {
    // Already active — return existing URL
    const session: CcSession = {
      directory: resolved,
      tmuxSession: tmuxName,
      url: existingMatch[0],
      startedBy: sender,
      chatJid,
      startedAt: new Date().toISOString(),
    };
    sessions.set(resolved, session);
    saveState();
    return { ok: true, url: existingMatch[0] };
  }

  try {
    // Send Escape first to ensure we're at the prompt, then /remote-control
    execFileSync(TMUX_BIN, ['send-keys', '-t', tmuxName, 'Escape', ''], {
      stdio: 'ignore',
      timeout: 5000,
    });
    // Small delay then send command
    execFileSync(
      TMUX_BIN,
      ['send-keys', '-t', tmuxName, '/remote-control', 'Enter'],
      { stdio: 'ignore', timeout: 5000 },
    );
  } catch (err: any) {
    return {
      ok: false,
      error: `Failed to reconnect session: ${err.message}`,
    };
  }

  logger.info({ tmuxName, directory: resolved }, 'CC session reconnecting');
  return pollForUrl(tmuxName, resolved, sender, chatJid, false, marker);
}

/**
 * Poll tmux pane for a claude.ai/code URL.
 * Prefers session-level URLs (from /remote-control handoff).
 * If marker is given, only match URLs that appear after the marker line.
 */
function pollForUrl(
  tmuxName: string,
  resolved: string,
  sender: string,
  chatJid: string,
  killOnTimeout: boolean,
  marker?: string,
): Promise<{ ok: true; url: string } | { ok: false; error: string }> {
  return new Promise((resolve) => {
    const startTime = Date.now();

    const poll = () => {
      if (!tmuxHasSession(tmuxName)) {
        resolve({
          ok: false,
          error: 'tmux session exited before producing URL',
        });
        return;
      }

      const content = tmuxCapture(tmuxName);
      const searchIn = marker
        ? content.slice(content.indexOf(marker) + marker.length)
        : content;

      // Prefer session-level URL, fall back to environment URL
      const match =
        searchIn.match(SESSION_URL_REGEX) || searchIn.match(ENV_URL_REGEX);

      if (match) {
        const session: CcSession = {
          directory: resolved,
          tmuxSession: tmuxName,
          url: match[0],
          startedBy: sender,
          chatJid,
          startedAt: new Date().toISOString(),
        };
        sessions.set(resolved, session);
        saveState();

        logger.info(
          { url: match[0], tmuxSession: tmuxName, directory: resolved, sender },
          'CC session ready',
        );
        resolve({ ok: true, url: match[0] });
        return;
      }

      if (Date.now() - startTime >= URL_TIMEOUT_MS) {
        if (killOnTimeout) {
          try {
            execFileSync(TMUX_BIN, ['kill-session', '-t', tmuxName], {
              stdio: 'ignore',
            });
          } catch {
            /* already dead */
          }
        }
        resolve({
          ok: false,
          error: 'Timed out waiting for Remote Control URL',
        });
        return;
      }

      setTimeout(poll, POLL_MS);
    };

    poll();
  });
}

export function stopCcSession(
  directory: string,
): { ok: true } | { ok: false; error: string } {
  const resolved = validateDirectory(directory);
  if (!resolved) {
    return { ok: false, error: `Invalid directory: ${directory}` };
  }

  const session = sessions.get(resolved);
  if (!session) {
    return { ok: false, error: `No active CC session for ${directory}` };
  }

  try {
    execFileSync(TMUX_BIN, ['kill-session', '-t', session.tmuxSession], {
      stdio: 'ignore',
    });
  } catch {
    /* already dead */
  }

  sessions.delete(resolved);
  saveState();
  logger.info(
    { directory: resolved, tmuxSession: session.tmuxSession },
    'CC session stopped',
  );
  return { ok: true };
}

export function listCcSessions(): CcSession[] {
  // Prune dead sessions
  for (const [dir, session] of sessions) {
    if (!tmuxHasSession(session.tmuxSession)) {
      sessions.delete(dir);
    }
  }
  saveState();
  return Array.from(sessions.values());
}

/**
 * Restore sessions from disk on startup.
 * Prunes any sessions whose tmux has died.
 */
export function restoreCcSessions(): void {
  let data: string;
  try {
    data = fs.readFileSync(STATE_FILE, 'utf-8');
  } catch {
    return;
  }

  try {
    const saved: CcSession[] = JSON.parse(data);
    for (const session of saved) {
      if (tmuxHasSession(session.tmuxSession)) {
        sessions.set(session.directory, session);
        logger.info(
          {
            tmuxSession: session.tmuxSession,
            directory: session.directory,
            url: session.url,
          },
          'Restored CC session from previous run',
        );
      }
    }
    // Persist pruned state
    saveState();
  } catch {
    // Corrupt state file — ignore
  }
}
