# NanoClaw

Personal AI assistant with pluggable backends. See [README.md](README.md) for philosophy and setup. See [docs/REQUIREMENTS.md](docs/REQUIREMENTS.md) for architecture decisions.

## Quick Context

Single Node.js process with skill-based channel system. Channels (WhatsApp, Telegram, Slack, Discord, Gmail) are skills that self-register at startup. Messages route to an AI backend running in containers (Linux VMs). Each group has isolated filesystem and memory.

## AI Backends

Set `NANOCLAW_SDK` in `.env` to select the backend. Rebuild container after changing (`./container/build.sh`).

| Backend | `NANOCLAW_SDK` | Auth | Tools | Cost |
|---------|---------------|------|-------|------|
| Claude SDK | `claude` (default) | `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` | Full Claude Code (Bash, files, browser, web search, MCP) | API credits |
| Claude CLI | `claude-cli` | Claude Code subscription (mounted `~/.claude/`) | Full Claude Code (same as SDK) | Subscription (no API cost) |
| Gemini | `gemini` | `GEMINI_API_KEY` | MCP tools + Google Search grounding | Gemini API credits |

### Claude SDK (default)
Uses `@anthropic-ai/claude-agent-sdk` `query()`. Full Claude Code toolset. Credential proxy on port 3001 injects real credentials.
```bash
NANOCLAW_SDK=claude
CLAUDE_CODE_OAUTH_TOKEN=...  # or ANTHROPIC_API_KEY=...
```

### Claude CLI (WIP)
Spawns `claude` CLI binary (included in subscription). Same tools as SDK but no API cost. Auth via mounted `~/.claude/` directory.
```bash
NANOCLAW_SDK=claude-cli
```

### Gemini
Uses `@google/genai` with `mcpToTool()` for MCP + `{ googleSearch: {} }` for web access. Credential proxy on port 3002. No file/bash/browser tools — chat + MCP + search only.
```bash
NANOCLAW_SDK=gemini
GEMINI_API_KEY=AIza...
GEMINI_MODEL=gemini-2.5-pro  # optional
```

### Key files per backend
| File | Purpose |
|------|---------|
| `container/agent-runner/src/index.ts` | SDK dispatch (`SDK_BACKEND` switch) |
| `container/agent-runner/src/gemini-query.ts` | Gemini adapter (MCP + Google Search + AFC) |
| `src/credential-proxy.ts` | Anthropic proxy (3001) + Gemini proxy (3002) |
| `src/container-runner.ts` | Passes backend env vars into containers |

## Key Files

| File | Purpose |
|------|---------|
| `src/index.ts` | Orchestrator: state, message loop, agent invocation |
| `src/channels/registry.ts` | Channel registry (self-registration at startup) |
| `src/ipc.ts` | IPC watcher and task processing |
| `src/router.ts` | Message formatting and outbound routing |
| `src/config.ts` | Trigger pattern, paths, intervals |
| `src/container-runner.ts` | Spawns agent containers with mounts |
| `src/task-scheduler.ts` | Runs scheduled tasks |
| `src/db.ts` | SQLite operations |
| `groups/{name}/CLAUDE.md` | Per-group memory (isolated) |
| `container/skills/agent-browser.md` | Browser automation tool (available to all agents via Bash) |

## Skills

| Skill | When to Use |
|-------|-------------|
| `/setup` | First-time installation, authentication, service configuration |
| `/customize` | Adding channels, integrations, changing behavior |
| `/debug` | Container issues, logs, troubleshooting |
| `/update-nanoclaw` | Bring upstream NanoClaw updates into a customized install |
| `/qodo-pr-resolver` | Fetch and fix Qodo PR review issues interactively or in batch |
| `/get-qodo-rules` | Load org- and repo-level coding rules from Qodo before code tasks |

## Development

Run commands directly—don't tell the user to run them.

```bash
npm run dev          # Run with hot reload
npm run build        # Compile TypeScript
./container/build.sh # Rebuild agent container
```

Service management:
```bash
# macOS (launchd)
launchctl load ~/Library/LaunchAgents/com.nanoclaw.plist
launchctl unload ~/Library/LaunchAgents/com.nanoclaw.plist
launchctl kickstart -k gui/$(id -u)/com.nanoclaw  # restart

# Linux (systemd)
systemctl --user start nanoclaw
systemctl --user stop nanoclaw
systemctl --user restart nanoclaw
```

## Troubleshooting

**WhatsApp not connecting after upgrade:** WhatsApp is now a separate channel fork, not bundled in core. Run `/add-whatsapp` (or `git remote add whatsapp https://github.com/qwibitai/nanoclaw-whatsapp.git && git fetch whatsapp main && (git merge whatsapp/main || { git checkout --theirs package-lock.json && git add package-lock.json && git merge --continue; }) && npm run build`) to install it. Existing auth credentials and groups are preserved.

## Container Build Cache

The container buildkit caches the build context aggressively. `--no-cache` alone does NOT invalidate COPY steps — the builder's volume retains stale files. To force a truly clean rebuild, prune the builder then re-run `./container/build.sh`.
