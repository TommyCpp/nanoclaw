import { vi, describe, it, expect, beforeEach, afterEach } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';

vi.mock('child_process', () => ({
  execFile: vi.fn((_cmd: string, _args: string[], cb: Function) => cb(null, '', '')),
}));

import { execFile as execFileCb } from 'child_process';
import { cloneOrPullRepo, runIssueCommand } from './github.js';

const mockExecFile = execFileCb as unknown as ReturnType<typeof vi.fn>;

function mockSuccess(stdout = '') {
  mockExecFile.mockImplementation(
    (_cmd: string, _args: string[], cb: Function) => cb(null, stdout, ''),
  );
}

function mockFailure(stderr: string) {
  mockExecFile.mockImplementation(
    (_cmd: string, _args: string[], cb: Function) =>
      cb(Object.assign(new Error(stderr), { stderr })),
  );
}

describe('cloneOrPullRepo', () => {
  beforeEach(() => {
    mockExecFile.mockClear();
    vi.spyOn(fs, 'mkdirSync').mockReturnValue(undefined as any);
    mockSuccess();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('clones repo when target directory does not exist', async () => {
    vi.spyOn(fs, 'existsSync').mockReturnValue(false);

    const result = await cloneOrPullRepo('owner/myrepo');

    expect(mockExecFile).toHaveBeenCalledWith(
      'gh',
      ['repo', 'clone', 'owner/myrepo', expect.stringContaining('myrepo')],
      expect.any(Function),
    );
    expect(result.ok).toBe(true);
    expect(result.message).toContain('cloned');
  });

  it('pulls when target directory has .git', async () => {
    const targetDir = path.join(os.homedir(), 'Dev', 'myrepo');
    vi.spyOn(fs, 'existsSync').mockImplementation((p) => {
      const s = String(p);
      if (s === targetDir) return true;
      if (s === path.join(targetDir, '.git')) return true;
      return false;
    });

    const result = await cloneOrPullRepo('owner/myrepo');

    expect(mockExecFile).toHaveBeenCalledWith(
      'git',
      ['-C', targetDir, 'pull'],
      expect.any(Function),
    );
    expect(result.ok).toBe(true);
    expect(result.message).toContain('updated');
  });

  it('returns error when directory exists but is not a git repo', async () => {
    const targetDir = path.join(os.homedir(), 'Dev', 'myrepo');
    vi.spyOn(fs, 'existsSync').mockImplementation((p) => {
      const s = String(p);
      if (s === targetDir) return true;
      if (s === path.join(targetDir, '.git')) return false;
      return false;
    });

    const result = await cloneOrPullRepo('owner/myrepo');

    expect(mockExecFile).not.toHaveBeenCalled();
    expect(result.ok).toBe(false);
    expect(result.message).toContain('not a git repo');
  });

  it('returns error when gh clone fails', async () => {
    vi.spyOn(fs, 'existsSync').mockReturnValue(false);
    mockFailure('repository not found');

    const result = await cloneOrPullRepo('owner/private-repo');

    expect(result.ok).toBe(false);
    expect(result.message).toContain('Clone failed');
  });

  it('returns error when git pull fails', async () => {
    const targetDir = path.join(os.homedir(), 'Dev', 'myrepo');
    vi.spyOn(fs, 'existsSync').mockImplementation((p) => {
      const s = String(p);
      return s === targetDir || s === path.join(targetDir, '.git');
    });
    mockFailure('merge conflict');

    const result = await cloneOrPullRepo('owner/myrepo');

    expect(result.ok).toBe(false);
    expect(result.message).toContain('Pull failed');
  });

  it('extracts repo name from full GitHub URL', async () => {
    vi.spyOn(fs, 'existsSync').mockReturnValue(false);

    await cloneOrPullRepo('https://github.com/owner/myrepo');

    expect(mockExecFile).toHaveBeenCalledWith(
      'gh',
      [
        'repo',
        'clone',
        'https://github.com/owner/myrepo',
        expect.stringContaining('myrepo'),
      ],
      expect.any(Function),
    );
  });
});

describe('runIssueCommand - allowlist', () => {
  const tmpAllowlist = path.join(os.tmpdir(), 'test-allowlist.json');

  beforeEach(() => {
    mockExecFile.mockClear();
    mockSuccess('[]');
    vi.spyOn(fs, 'mkdirSync').mockReturnValue(undefined as any);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('rejects repo not in allowlist', async () => {
    vi.spyOn(fs, 'readFileSync').mockReturnValue(
      JSON.stringify(['other/repo']) as any,
    );

    const result = await runIssueCommand(
      'gh_list_issues',
      { repo: 'owner/myrepo' },
      tmpAllowlist,
    );

    expect(result.ok).toBe(false);
    expect(result.message).toContain('not in the allowlist');
    expect(mockExecFile).not.toHaveBeenCalled();
  });

  it('returns error when allowlist file is missing', async () => {
    vi.spyOn(fs, 'readFileSync').mockImplementation(() => {
      throw new Error('ENOENT');
    });

    const result = await runIssueCommand(
      'gh_list_issues',
      { repo: 'owner/myrepo' },
      '/nonexistent/path.json',
    );

    expect(result.ok).toBe(false);
    expect(result.message).toContain('not in the allowlist');
  });

  it('runs gh issue list for allowlisted repo', async () => {
    vi.spyOn(fs, 'readFileSync').mockReturnValue(
      JSON.stringify(['owner/myrepo']) as any,
    );

    const result = await runIssueCommand(
      'gh_list_issues',
      { repo: 'owner/myrepo', state: 'open' },
      tmpAllowlist,
    );

    expect(mockExecFile).toHaveBeenCalledWith(
      'gh',
      expect.arrayContaining(['issue', 'list', '--repo', 'owner/myrepo']),
      expect.any(Function),
    );
    expect(result.ok).toBe(true);
  });

  it('runs gh issue view for allowlisted repo', async () => {
    vi.spyOn(fs, 'readFileSync').mockReturnValue(
      JSON.stringify(['owner/myrepo']) as any,
    );
    mockSuccess('{"number":1}');

    const result = await runIssueCommand(
      'gh_get_issue',
      { repo: 'owner/myrepo', issue_number: 1 },
      tmpAllowlist,
    );

    expect(mockExecFile).toHaveBeenCalledWith(
      'gh',
      expect.arrayContaining(['issue', 'view', '1', '--repo', 'owner/myrepo']),
      expect.any(Function),
    );
    expect(result.ok).toBe(true);
  });

  it('runs gh issue create', async () => {
    vi.spyOn(fs, 'readFileSync').mockReturnValue(
      JSON.stringify(['owner/myrepo']) as any,
    );

    const result = await runIssueCommand(
      'gh_create_issue',
      { repo: 'owner/myrepo', title: 'Bug', body: 'Description' },
      tmpAllowlist,
    );

    expect(mockExecFile).toHaveBeenCalledWith(
      'gh',
      expect.arrayContaining([
        'issue',
        'create',
        '--repo',
        'owner/myrepo',
        '--title',
        'Bug',
      ]),
      expect.any(Function),
    );
    expect(result.ok).toBe(true);
  });

  it('runs gh issue comment', async () => {
    vi.spyOn(fs, 'readFileSync').mockReturnValue(
      JSON.stringify(['owner/myrepo']) as any,
    );

    const result = await runIssueCommand(
      'gh_comment_issue',
      { repo: 'owner/myrepo', issue_number: 5, body: 'LGTM' },
      tmpAllowlist,
    );

    expect(mockExecFile).toHaveBeenCalledWith(
      'gh',
      expect.arrayContaining([
        'issue',
        'comment',
        '5',
        '--repo',
        'owner/myrepo',
      ]),
      expect.any(Function),
    );
    expect(result.ok).toBe(true);
  });

  it('runs gh issue close', async () => {
    vi.spyOn(fs, 'readFileSync').mockReturnValue(
      JSON.stringify(['owner/myrepo']) as any,
    );

    const result = await runIssueCommand(
      'gh_close_issue',
      { repo: 'owner/myrepo', issue_number: 3 },
      tmpAllowlist,
    );

    expect(mockExecFile).toHaveBeenCalledWith(
      'gh',
      expect.arrayContaining(['issue', 'close', '3', '--repo', 'owner/myrepo']),
      expect.any(Function),
    );
    expect(result.ok).toBe(true);
  });

  it('runs gh issue reopen', async () => {
    vi.spyOn(fs, 'readFileSync').mockReturnValue(
      JSON.stringify(['owner/myrepo']) as any,
    );

    const result = await runIssueCommand(
      'gh_reopen_issue',
      { repo: 'owner/myrepo', issue_number: 3 },
      tmpAllowlist,
    );

    expect(mockExecFile).toHaveBeenCalledWith(
      'gh',
      expect.arrayContaining([
        'issue',
        'reopen',
        '3',
        '--repo',
        'owner/myrepo',
      ]),
      expect.any(Function),
    );
    expect(result.ok).toBe(true);
  });

  it('runs gh issue edit to add labels', async () => {
    vi.spyOn(fs, 'readFileSync').mockReturnValue(
      JSON.stringify(['owner/myrepo']) as any,
    );

    const result = await runIssueCommand(
      'gh_add_labels',
      { repo: 'owner/myrepo', issue_number: 7, labels: ['bug', 'urgent'] },
      tmpAllowlist,
    );

    expect(mockExecFile).toHaveBeenCalledWith(
      'gh',
      expect.arrayContaining([
        'issue',
        'edit',
        '7',
        '--repo',
        'owner/myrepo',
        '--add-label',
        'bug,urgent',
      ]),
      expect.any(Function),
    );
    expect(result.ok).toBe(true);
  });

  it('runs gh issue edit to set assignees', async () => {
    vi.spyOn(fs, 'readFileSync').mockReturnValue(
      JSON.stringify(['owner/myrepo']) as any,
    );

    const result = await runIssueCommand(
      'gh_set_assignees',
      { repo: 'owner/myrepo', issue_number: 2, assignees: ['alice', 'bob'] },
      tmpAllowlist,
    );

    expect(mockExecFile).toHaveBeenCalledWith(
      'gh',
      expect.arrayContaining([
        'issue',
        'edit',
        '2',
        '--repo',
        'owner/myrepo',
        '--assignee',
        'alice,bob',
      ]),
      expect.any(Function),
    );
    expect(result.ok).toBe(true);
  });

  it('returns error when gh command fails', async () => {
    vi.spyOn(fs, 'readFileSync').mockReturnValue(
      JSON.stringify(['owner/myrepo']) as any,
    );
    mockFailure('gh: not found');

    const result = await runIssueCommand(
      'gh_close_issue',
      { repo: 'owner/myrepo', issue_number: 1 },
      tmpAllowlist,
    );

    expect(result.ok).toBe(false);
    expect(result.message).toContain('failed');
  });

  it('returns error for unknown issue command type', async () => {
    vi.spyOn(fs, 'readFileSync').mockReturnValue(
      JSON.stringify(['owner/myrepo']) as any,
    );

    const result = await runIssueCommand(
      'gh_unknown_command',
      { repo: 'owner/myrepo' },
      tmpAllowlist,
    );

    expect(result.ok).toBe(false);
    expect(mockExecFile).not.toHaveBeenCalled();
  });
});
