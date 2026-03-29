import { vi, describe, it, expect, beforeEach } from 'vitest';

vi.mock('./github.js', () => ({
  ALLOWED_REPOS_PATH: '/mock/config/allowed-repos.json',
  cloneOrPullRepo: vi.fn().mockResolvedValue({
    ok: true,
    message: 'owner/myrepo cloned to ~/Dev/myrepo',
  }),
  runIssueCommand: vi
    .fn()
    .mockResolvedValue({ ok: true, message: 'Issues listed' }),
}));

import { _initTestDatabase, setRegisteredGroup } from './db.js';
import { cloneOrPullRepo, runIssueCommand } from './github.js';
import { processTaskIpc, IpcDeps } from './ipc.js';
import { RegisteredGroup } from './types.js';

const MAIN_GROUP: RegisteredGroup = {
  name: 'Main',
  folder: 'whatsapp_main',
  trigger: 'always',
  added_at: '2024-01-01T00:00:00.000Z',
  isMain: true,
};

const OTHER_GROUP: RegisteredGroup = {
  name: 'Other',
  folder: 'other-group',
  trigger: '@Andy',
  added_at: '2024-01-01T00:00:00.000Z',
};

let groups: Record<string, RegisteredGroup>;
let sentMessages: { jid: string; text: string }[];
let deps: IpcDeps;

beforeEach(() => {
  vi.clearAllMocks();
  _initTestDatabase();

  groups = {
    'main@g.us': MAIN_GROUP,
    'other@g.us': OTHER_GROUP,
  };

  setRegisteredGroup('main@g.us', MAIN_GROUP);
  setRegisteredGroup('other@g.us', OTHER_GROUP);

  sentMessages = [];
  deps = {
    sendMessage: async (jid, text) => {
      sentMessages.push({ jid, text });
    },
    registeredGroups: () => groups,
    registerGroup: () => {},
    syncGroups: async () => {},
    getAvailableGroups: () => [],
    writeGroupsSnapshot: () => {},
    onTasksChanged: () => {},
  };

  vi.mocked(cloneOrPullRepo).mockResolvedValue({
    ok: true,
    message: 'owner/myrepo cloned to ~/Dev/myrepo',
  });
  vi.mocked(runIssueCommand).mockResolvedValue({
    ok: true,
    message: 'Issues listed',
  });
});

// --- clone_repo IPC ---

describe('clone_repo IPC', () => {
  it('main group clone_repo calls cloneOrPullRepo and sends result', async () => {
    await processTaskIpc(
      { type: 'clone_repo', repo: 'owner/myrepo', chatJid: 'main@g.us' },
      'whatsapp_main',
      true,
      deps,
    );

    expect(cloneOrPullRepo).toHaveBeenCalledWith('owner/myrepo');
    expect(sentMessages).toHaveLength(1);
    expect(sentMessages[0].text).toBe('owner/myrepo cloned to ~/Dev/myrepo');
  });

  it('main group clone_repo sends error message when clone fails', async () => {
    vi.mocked(cloneOrPullRepo).mockResolvedValue({
      ok: false,
      message: 'Clone failed: repository not found',
    });

    await processTaskIpc(
      { type: 'clone_repo', repo: 'owner/missing', chatJid: 'main@g.us' },
      'whatsapp_main',
      true,
      deps,
    );

    expect(sentMessages).toHaveLength(1);
    expect(sentMessages[0].text).toContain('Clone failed');
  });

  it('non-main cannot use clone_repo', async () => {
    await processTaskIpc(
      { type: 'clone_repo', repo: 'owner/myrepo', chatJid: 'other@g.us' },
      'other-group',
      false,
      deps,
    );

    expect(cloneOrPullRepo).not.toHaveBeenCalled();
    expect(sentMessages).toHaveLength(0);
  });
});

// --- gh_* issue IPC ---

describe('gh_list_issues IPC', () => {
  it('main group can list issues', async () => {
    await processTaskIpc(
      {
        type: 'gh_list_issues',
        repo: 'owner/myrepo',
        chatJid: 'main@g.us',
        state: 'open',
      },
      'whatsapp_main',
      true,
      deps,
    );

    expect(runIssueCommand).toHaveBeenCalledWith(
      'gh_list_issues',
      expect.objectContaining({ repo: 'owner/myrepo', state: 'open' }),
      expect.any(String),
    );
    expect(sentMessages).toHaveLength(1);
    expect(sentMessages[0].text).toBe('Issues listed');
  });

  it('non-main cannot list issues', async () => {
    await processTaskIpc(
      { type: 'gh_list_issues', repo: 'owner/myrepo', chatJid: 'other@g.us' },
      'other-group',
      false,
      deps,
    );

    expect(runIssueCommand).not.toHaveBeenCalled();
    expect(sentMessages).toHaveLength(0);
  });
});

describe('gh issue command IPC', () => {
  const mainIssueTypes = [
    'gh_get_issue',
    'gh_create_issue',
    'gh_comment_issue',
    'gh_close_issue',
    'gh_reopen_issue',
    'gh_add_labels',
    'gh_set_assignees',
  ] as const;

  for (const type of mainIssueTypes) {
    it(`main group can use ${type}`, async () => {
      await processTaskIpc(
        { type, repo: 'owner/myrepo', chatJid: 'main@g.us', issue_number: 1 },
        'whatsapp_main',
        true,
        deps,
      );

      expect(runIssueCommand).toHaveBeenCalledWith(
        type,
        expect.objectContaining({ repo: 'owner/myrepo' }),
        expect.any(String),
      );
      expect(sentMessages).toHaveLength(1);
    });

    it(`non-main cannot use ${type}`, async () => {
      await processTaskIpc(
        { type, repo: 'owner/myrepo', chatJid: 'other@g.us', issue_number: 1 },
        'other-group',
        false,
        deps,
      );

      expect(runIssueCommand).not.toHaveBeenCalled();
      expect(sentMessages).toHaveLength(0);
    });
  }
});
