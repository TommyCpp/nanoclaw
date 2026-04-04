/**
 * Claude CLI query adapter for NanoClaw
 *
 * Spawns the `claude` CLI binary (included in Claude subscription) instead
 * of using the Agent SDK (which requires API credits). Gets the full Claude
 * Code toolset (Bash, Read, Write, WebSearch, agent-browser, etc.) at no
 * additional API cost.
 *
 * Uses `--print --output-format json` for non-interactive single-turn queries,
 * with `--resume` for session continuity across the IPC message loop.
 */

import { spawn, ChildProcess } from 'child_process';
import fs from 'fs';
import path from 'path';

// ---------------------------------------------------------------------------
// Types (matching agent-runner conventions)
// ---------------------------------------------------------------------------

interface ContainerInput {
  prompt: string;
  sessionId?: string;
  groupFolder: string;
  chatJid: string;
  isMain: boolean;
  isScheduledTask?: boolean;
  assistantName?: string;
}

interface ContainerOutput {
  status: 'success' | 'error';
  result: string | null;
  newSessionId?: string;
  error?: string;
}

export interface ClaudeCliQueryResult {
  newSessionId?: string;
  lastAssistantUuid?: string;
  closedDuringQuery: boolean;
}

interface ClaudeJsonResult {
  type: string;
  subtype: string;
  result?: string;
  session_id?: string;
  is_error?: boolean;
  uuid?: string;
}

type WriteOutputFn = (output: ContainerOutput) => void;
type LogFn = (message: string) => void;
type ShouldCloseFn = () => boolean;
type DrainIpcFn = () => string[];

// ---------------------------------------------------------------------------
// Build CLI arguments
// ---------------------------------------------------------------------------

function buildClaudeArgs(
  prompt: string,
  sessionId: string | undefined,
  mcpServerPath: string,
  containerInput: ContainerInput,
): string[] {
  const args: string[] = [
    '--print',
    '--output-format', 'json',
    '--dangerously-skip-permissions',
    '--bare',
  ];

  // Resume existing session
  if (sessionId) {
    args.push('--resume', sessionId);
  }

  // MCP server config as JSON
  const mcpConfig = {
    mcpServers: {
      nanoclaw: {
        command: 'node',
        args: [mcpServerPath],
        env: {
          NANOCLAW_CHAT_JID: containerInput.chatJid,
          NANOCLAW_GROUP_FOLDER: containerInput.groupFolder,
          NANOCLAW_IS_MAIN: containerInput.isMain ? '1' : '0',
        },
      },
    },
  };
  args.push('--mcp-config', JSON.stringify(mcpConfig));

  // Working directory
  args.push('--add-dir', '/workspace/group');

  // System prompt from global CLAUDE.md
  const globalClaudeMdPath = '/workspace/global/CLAUDE.md';
  if (!containerInput.isMain && fs.existsSync(globalClaudeMdPath)) {
    const systemPrompt = fs.readFileSync(globalClaudeMdPath, 'utf-8');
    args.push('--append-system-prompt', systemPrompt);
  }

  // Allowed tools — match what the SDK backend allows
  args.push(
    '--allowedTools',
    'Bash', 'Read', 'Write', 'Edit', 'Glob', 'Grep',
    'WebSearch', 'WebFetch',
    'Task', 'TaskOutput', 'TaskStop',
    'TodoWrite', 'ToolSearch', 'Skill',
    'NotebookEdit',
    'mcp__nanoclaw__*',
  );

  // The prompt itself
  args.push(prompt);

  return args;
}

// ---------------------------------------------------------------------------
// Query implementation
// ---------------------------------------------------------------------------

export async function runClaudeCliQuery(
  prompt: string,
  sessionId: string | undefined,
  mcpServerPath: string,
  containerInput: ContainerInput,
  _sdkEnv: Record<string, string | undefined>,
  writeOutput: WriteOutputFn,
  log: LogFn,
  shouldClose: ShouldCloseFn,
  drainIpcInput: DrainIpcFn,
  ipcPollMs: number,
): Promise<ClaudeCliQueryResult> {
  const args = buildClaudeArgs(prompt, sessionId, mcpServerPath, containerInput);
  const model = process.env.CLAUDE_CLI_MODEL;

  if (model) {
    // Insert --model before the prompt (last arg)
    args.splice(args.length - 1, 0, '--model', model);
  }

  log(`Claude CLI query (session: ${sessionId || 'new'}, model: ${model || 'default'})`);
  log(`  args: claude ${args.slice(0, -1).join(' ')} "<prompt>"`);

  return new Promise<ClaudeCliQueryResult>((resolve, reject) => {
    let stdout = '';
    let stderr = '';
    let closedDuringQuery = false;

    const proc: ChildProcess = spawn('claude', args, {
      cwd: '/workspace/group',
      env: {
        ...process.env,
        // Ensure claude CLI doesn't try interactive prompts
        CI: '1',
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    // IPC polling during query
    let ipcPolling = true;
    const pollIpc = () => {
      if (!ipcPolling) return;
      if (shouldClose()) {
        log('Close sentinel detected during Claude CLI query, killing process');
        closedDuringQuery = true;
        ipcPolling = false;
        proc.kill('SIGTERM');
        return;
      }
      drainIpcInput(); // drain — IPC messages handled between queries by main loop
      setTimeout(pollIpc, ipcPollMs);
    };
    setTimeout(pollIpc, ipcPollMs);

    proc.stdout?.on('data', (chunk: Buffer) => {
      stdout += chunk.toString();
    });

    proc.stderr?.on('data', (chunk: Buffer) => {
      stderr += chunk.toString();
    });

    proc.on('error', (err) => {
      ipcPolling = false;
      log(`Claude CLI spawn error: ${err.message}`);
      writeOutput({
        status: 'error',
        result: null,
        error: `Failed to spawn claude CLI: ${err.message}`,
      });
      resolve({ closedDuringQuery });
    });

    proc.on('close', (code) => {
      ipcPolling = false;

      if (stderr) {
        log(`Claude CLI stderr: ${stderr.slice(0, 500)}`);
      }

      if (closedDuringQuery) {
        log('Claude CLI killed due to close sentinel');
        resolve({ closedDuringQuery: true });
        return;
      }

      // Parse JSON output
      try {
        const result: ClaudeJsonResult = JSON.parse(stdout);

        const newSessionId = result.session_id;
        const text = result.result || null;

        if (result.is_error || result.subtype === 'error') {
          log(`Claude CLI error result: ${text}`);
          writeOutput({
            status: 'error',
            result: null,
            newSessionId,
            error: text || 'Claude CLI returned an error',
          });
        } else {
          if (text) {
            log(`Claude CLI result (${text.length} chars): ${text.slice(0, 200)}`);
          }
          writeOutput({
            status: 'success',
            result: text,
            newSessionId,
          });
        }

        resolve({
          newSessionId,
          lastAssistantUuid: result.uuid,
          closedDuringQuery: false,
        });
      } catch (parseErr) {
        log(`Claude CLI output parse error (exit code ${code}): ${stdout.slice(0, 500)}`);
        writeOutput({
          status: 'error',
          result: null,
          error: `Claude CLI exited with code ${code}: ${stderr || stdout.slice(0, 200)}`,
        });
        resolve({ closedDuringQuery: false });
      }
    });
  });
}

export async function stopClaudeCliClient(): Promise<void> {
  // No persistent client to clean up — each query spawns a fresh process
}
