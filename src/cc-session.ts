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

const URL_REGEX = /https:\/\/claude\.ai\/code\S+/;
const URL_TIMEOUT_MS = 30_000;
const URL_POLL_MS = 200;
const STATE_FILE = path.join(DATA_DIR, 'cc-sessions.json');

function saveState(): void {
  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(
    STATE_FILE,
    JSON.stringify(Array.from(sessions.values()), null, 2),
  );
}

function sanitizeSessionName(dir: string): string {
  const base = path.basename(dir);
  return `cc-${base.replace(/[^a-zA-Z0-9-]/g, '-').toLowerCase().slice(0, 50)}`;
}

function tmuxHasSession(name: string): boolean {
  try {
    execFileSync(TMUX_BIN,['has-session', '-t', name], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

function tmuxCapture(name: string): string {
  try {
    return execFileSync(TMUX_BIN,['capture-pane', '-p', '-t', name, '-S', '-50'], {
      encoding: 'utf-8',
      timeout: 5000,
    });
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
    // Tmux session alive — reconnect by restarting remote-control in it
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

  // Start tmux session with claude remote-control
  try {
    execFileSync(
      TMUX_BIN,
      [
        'new-session',
        '-d',
        '-s', tmuxName,
        '-c', resolved,
        '--',
        CLAUDE_BIN,
        'remote-control',
        '--name', `CC: ${path.basename(resolved)}`,
        '--permission-mode', 'bypassPermissions',
      ],
      { stdio: 'ignore', timeout: 10_000 },
    );
  } catch (err: any) {
    return { ok: false, error: `Failed to start tmux session: ${err.message}` };
  }

  return pollForUrl(tmuxName, resolved!, sender, chatJid, true);
}

/**
 * Restart claude remote-control inside an existing tmux session and wait for new URL.
 * Uses a marker line to distinguish the new URL from any old URL still in scrollback.
 */
async function reconnectCcSession(
  tmuxName: string,
  resolved: string,
  sender: string,
  chatJid: string,
): Promise<{ ok: true; url: string } | { ok: false; error: string }> {
  const marker = `__CC_RECONNECT_${Date.now()}__`;
  try {
    // Print marker then run remote-control — marker lets us ignore scrollback above it
    execFileSync(TMUX_BIN, [
      'send-keys', '-t', tmuxName,
      `echo ${marker} && ${CLAUDE_BIN} remote-control --name "CC: ${path.basename(resolved)}" --permission-mode bypassPermissions`,
      'Enter',
    ], { stdio: 'ignore', timeout: 5000 });
  } catch (err: any) {
    return { ok: false, error: `Failed to reconnect tmux session: ${err.message}` };
  }

  logger.info({ tmuxName, directory: resolved }, 'CC session reconnecting');
  return pollForUrl(tmuxName, resolved, sender, chatJid, false, marker);
}

/**
 * Poll tmux pane for a claude.ai/code URL.
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
        resolve({ ok: false, error: 'tmux session exited before producing URL' });
        return;
      }

      const content = tmuxCapture(tmuxName);
      const searchIn = marker
        ? content.slice(content.indexOf(marker) + marker.length)
        : content;
      const match = searchIn.match(URL_REGEX);

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
            execFileSync(TMUX_BIN, ['kill-session', '-t', tmuxName], { stdio: 'ignore' });
          } catch { /* already dead */ }
        }
        resolve({ ok: false, error: 'Timed out waiting for Remote Control URL' });
        return;
      }

      setTimeout(poll, URL_POLL_MS);
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
    execFileSync(TMUX_BIN,['kill-session', '-t', session.tmuxSession], {
      stdio: 'ignore',
    });
  } catch { /* already dead */ }

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
          { tmuxSession: session.tmuxSession, directory: session.directory, url: session.url },
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
