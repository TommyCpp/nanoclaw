/**
 * Google Gemini SDK query adapter for NanoClaw
 *
 * Provides a query interface compatible with the agent-runner's main loop,
 * using the Google GenAI SDK instead of the Anthropic Claude Agent SDK.
 *
 * Uses mcpToTool() for automatic function calling — the SDK handles the
 * tool-call loop internally (call tool → feed result → repeat until done).
 * We configure maximumRemoteCalls to cap iterations.
 */

import { GoogleGenAI, type Content, mcpToTool } from '@google/genai';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import fs from 'fs';
import path from 'path';
import { randomUUID } from 'crypto';

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

export interface GeminiQueryResult {
  newSessionId?: string;
  closedDuringQuery: boolean;
}

type WriteOutputFn = (output: ContainerOutput) => void;
type LogFn = (message: string) => void;
type ShouldCloseFn = () => boolean;
type DrainIpcFn = () => string[];

// ---------------------------------------------------------------------------
// MCP client (reused across queries within one container run)
// ---------------------------------------------------------------------------

let mcpClient: Client | null = null;
let mcpTransport: StdioClientTransport | null = null;

async function ensureMcpClient(
  mcpServerPath: string,
  containerInput: ContainerInput,
  log: LogFn,
): Promise<Client> {
  if (mcpClient) return mcpClient;

  log('Starting MCP server for Gemini adapter');
  mcpTransport = new StdioClientTransport({
    command: 'node',
    args: [mcpServerPath],
    env: {
      ...process.env,
      NANOCLAW_CHAT_JID: containerInput.chatJid,
      NANOCLAW_GROUP_FOLDER: containerInput.groupFolder,
      NANOCLAW_IS_MAIN: containerInput.isMain ? '1' : '0',
    },
  });

  mcpClient = new Client({ name: 'nanoclaw-gemini', version: '1.0.0' });
  await mcpClient.connect(mcpTransport);
  log('MCP client connected');
  return mcpClient;
}

export async function stopGeminiClient(): Promise<void> {
  if (mcpClient) {
    try { await mcpClient.close(); } catch { /* ignore */ }
    mcpClient = null;
  }
  if (mcpTransport) {
    try { await mcpTransport.close(); } catch { /* ignore */ }
    mcpTransport = null;
  }
}

// ---------------------------------------------------------------------------
// Session persistence
// ---------------------------------------------------------------------------

const SESSIONS_DIR = '/workspace/group/.gemini-sessions';

function loadSession(sessionId: string, log: LogFn): Content[] | null {
  const filePath = path.join(SESSIONS_DIR, `${sessionId}.json`);
  if (!fs.existsSync(filePath)) return null;
  try {
    const data = JSON.parse(fs.readFileSync(filePath, 'utf-8'));
    return data.history ?? null;
  } catch (err) {
    log(`Failed to load Gemini session ${sessionId}: ${err instanceof Error ? err.message : String(err)}`);
    return null;
  }
}

function saveSession(sessionId: string, history: Content[], log: LogFn): void {
  fs.mkdirSync(SESSIONS_DIR, { recursive: true });
  const filePath = path.join(SESSIONS_DIR, `${sessionId}.json`);
  try {
    fs.writeFileSync(filePath, JSON.stringify({ history }));
  } catch (err) {
    log(`Failed to save Gemini session ${sessionId}: ${err instanceof Error ? err.message : String(err)}`);
  }
}

// ---------------------------------------------------------------------------
// Query implementation
// ---------------------------------------------------------------------------

const MAX_TOOL_ITERATIONS = 50;

export async function runGeminiQuery(
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
): Promise<GeminiQueryResult> {
  const model = process.env.GEMINI_MODEL || 'gemini-2.5-pro';
  const baseUrl = process.env.GEMINI_BASE_URL;
  const apiKey = process.env.GEMINI_API_KEY || 'placeholder';

  log(`Gemini query (model: ${model}, session: ${sessionId || 'new'}, baseUrl: ${baseUrl || 'default'})`);

  // Initialize MCP client
  const mcp = await ensureMcpClient(mcpServerPath, containerInput, log);

  // Initialize Gemini client
  const ai = new GoogleGenAI({
    apiKey,
    ...(baseUrl ? { httpOptions: { baseUrl } } : {}),
  });

  // Convert MCP tools to Gemini-compatible callable tools
  const tools = [mcpToTool(mcp)];

  // Load system instruction from global CLAUDE.md
  const globalClaudeMdPath = '/workspace/global/CLAUDE.md';
  let systemInstruction: string | undefined;
  if (!containerInput.isMain && fs.existsSync(globalClaudeMdPath)) {
    systemInstruction = fs.readFileSync(globalClaudeMdPath, 'utf-8');
  }

  // Create or resume session
  const newSessionId = sessionId || randomUUID();
  const existingHistory = sessionId ? loadSession(sessionId, log) : null;

  const chat = ai.chats.create({
    model,
    config: {
      tools,
      ...(systemInstruction ? { systemInstruction } : {}),
      automaticFunctionCalling: {
        maximumRemoteCalls: MAX_TOOL_ITERATIONS,
      },
    },
    ...(existingHistory ? { history: existingHistory } : {}),
  });

  // IPC polling
  let ipcPolling = true;
  let closedDuringQuery = false;

  const pollIpc = () => {
    if (!ipcPolling) return;
    if (shouldClose()) {
      log('Close sentinel detected during Gemini query');
      closedDuringQuery = true;
      ipcPolling = false;
      return;
    }
    drainIpcInput(); // drain but don't inject mid-loop — handled between queries by main loop
    setTimeout(pollIpc, ipcPollMs);
  };
  setTimeout(pollIpc, ipcPollMs);

  try {
    // Send message — automatic function calling handles the tool loop
    const response = await chat.sendMessage({ message: prompt });

    // Log automatic function calling history if available
    const afcHistory = response.automaticFunctionCallingHistory;
    if (afcHistory && afcHistory.length > 0) {
      log(`Automatic function calling: ${afcHistory.length} round-trip(s)`);
    }

    // Extract text from final response
    const text = response.text ?? null;
    if (text) {
      log(`Gemini result (${text.length} chars): ${text.slice(0, 200)}`);
    }

    writeOutput({
      status: 'success',
      result: text,
      newSessionId,
    });

    // Persist session history for resumption
    try {
      const history = chat.getHistory();
      if (history && history.length > 0) {
        saveSession(newSessionId, history, log);
      }
    } catch {
      log('Could not persist session history');
    }

    return { newSessionId, closedDuringQuery };
  } catch (err) {
    const errorMessage = err instanceof Error ? err.message : String(err);
    log(`Gemini query error: ${errorMessage}`);
    writeOutput({
      status: 'error',
      result: null,
      newSessionId,
      error: errorMessage,
    });
    return { newSessionId, closedDuringQuery };
  } finally {
    ipcPolling = false;
  }
}
