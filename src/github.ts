import { execFile as execFileCb } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';

// Resolve a command by searching common install locations when not in PATH.
// launchd services run with a minimal PATH that excludes Homebrew (/opt/homebrew/bin).
function resolveCmd(cmd: string): string {
  const extraPaths = ['/opt/homebrew/bin', '/usr/local/bin'];
  for (const dir of extraPaths) {
    const full = path.join(dir, cmd);
    if (fs.existsSync(full)) return full;
  }
  return cmd;
}

function execFile(
  cmd: string,
  args: string[],
): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    execFileCb(resolveCmd(cmd), args, (err, stdout, stderr) => {
      if (err) reject(err);
      else resolve({ stdout: String(stdout), stderr: String(stderr) });
    });
  });
}

export const ALLOWED_REPOS_PATH = path.join(
  process.cwd(),
  'config',
  'allowed-repos.json',
);

export interface IssueCommandData {
  repo: string;
  issue_number?: number;
  title?: string;
  body?: string;
  labels?: string[];
  assignees?: string[];
  state?: string;
  assignee?: string;
  limit?: number;
}

function readAllowlist(allowlistPath = ALLOWED_REPOS_PATH): string[] {
  try {
    return JSON.parse(fs.readFileSync(allowlistPath, 'utf-8'));
  } catch {
    return [];
  }
}

function repoBaseName(repo: string): string {
  // Handle full URLs and owner/repo shorthand; strip .git suffix
  return path.basename(repo.replace(/\.git$/, ''));
}

export async function cloneOrPullRepo(
  repo: string,
): Promise<{ ok: boolean; message: string }> {
  const name = repoBaseName(repo);
  const devDir = path.join(os.homedir(), 'Dev');
  const targetDir = path.join(devDir, name);

  fs.mkdirSync(devDir, { recursive: true });

  if (!fs.existsSync(targetDir)) {
    try {
      await execFile('gh', ['repo', 'clone', repo, targetDir]);
      return { ok: true, message: `${repo} cloned to ~/Dev/${name}` };
    } catch (err: any) {
      return {
        ok: false,
        message: `Clone failed: ${err.stderr || err.message}`,
      };
    }
  } else if (fs.existsSync(path.join(targetDir, '.git'))) {
    try {
      await execFile('git', ['-C', targetDir, 'pull']);
      return { ok: true, message: `~/Dev/${name} updated (pulled)` };
    } catch (err: any) {
      return {
        ok: false,
        message: `Pull failed: ${err.stderr || err.message}`,
      };
    }
  } else {
    return {
      ok: false,
      message: `~/Dev/${name} exists but is not a git repo`,
    };
  }
}

export async function runIssueCommand(
  type: string,
  data: IssueCommandData,
  allowlistPath?: string,
): Promise<{ ok: boolean; message: string }> {
  const allowlist = readAllowlist(allowlistPath);
  if (!allowlist.includes(data.repo)) {
    return {
      ok: false,
      message: `Repo ${data.repo} is not in the allowlist. Add it to config/allowed-repos.json.`,
    };
  }

  try {
    switch (type) {
      case 'gh_list_issues': {
        const args = [
          'issue',
          'list',
          '--repo',
          data.repo,
          '--state',
          data.state || 'open',
          '--json',
          'number,title,state,labels,assignees,createdAt',
        ];
        if (data.labels?.length) args.push('--label', data.labels.join(','));
        if (data.assignee) args.push('--assignee', data.assignee);
        if (data.limit) args.push('--limit', String(data.limit));
        const { stdout } = await execFile('gh', args);
        return { ok: true, message: stdout || '[]' };
      }

      case 'gh_get_issue': {
        const { stdout } = await execFile('gh', [
          'issue',
          'view',
          String(data.issue_number),
          '--repo',
          data.repo,
          '--json',
          'number,title,state,body,labels,assignees,comments',
        ]);
        return { ok: true, message: stdout };
      }

      case 'gh_create_issue': {
        const args = [
          'issue',
          'create',
          '--repo',
          data.repo,
          '--title',
          data.title || '',
          '--body',
          data.body || '',
        ];
        if (data.labels?.length) args.push('--label', data.labels.join(','));
        if (data.assignees?.length)
          args.push('--assignee', data.assignees.join(','));
        const { stdout } = await execFile('gh', args);
        return { ok: true, message: stdout.trim() || 'Issue created.' };
      }

      case 'gh_comment_issue': {
        await execFile('gh', [
          'issue',
          'comment',
          String(data.issue_number),
          '--repo',
          data.repo,
          '--body',
          data.body || '',
        ]);
        return { ok: true, message: 'Comment added.' };
      }

      case 'gh_close_issue': {
        await execFile('gh', [
          'issue',
          'close',
          String(data.issue_number),
          '--repo',
          data.repo,
        ]);
        return {
          ok: true,
          message: `Issue #${data.issue_number} closed.`,
        };
      }

      case 'gh_reopen_issue': {
        await execFile('gh', [
          'issue',
          'reopen',
          String(data.issue_number),
          '--repo',
          data.repo,
        ]);
        return {
          ok: true,
          message: `Issue #${data.issue_number} reopened.`,
        };
      }

      case 'gh_add_labels': {
        await execFile('gh', [
          'issue',
          'edit',
          String(data.issue_number),
          '--repo',
          data.repo,
          '--add-label',
          (data.labels || []).join(','),
        ]);
        return { ok: true, message: 'Labels added.' };
      }

      case 'gh_set_assignees': {
        await execFile('gh', [
          'issue',
          'edit',
          String(data.issue_number),
          '--repo',
          data.repo,
          '--assignee',
          (data.assignees || []).join(','),
        ]);
        return { ok: true, message: 'Assignees set.' };
      }

      default:
        return { ok: false, message: `Unknown issue command: ${type}` };
    }
  } catch (err: any) {
    return {
      ok: false,
      message: `Command failed: ${err.stderr || err.message}`,
    };
  }
}
