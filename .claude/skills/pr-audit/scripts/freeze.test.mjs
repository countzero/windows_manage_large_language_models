/**
 * The texts `freeze.mjs` writes from what git, `gh` and the orchestrator give it.
 *
 *   node --test .claude/skills/pr-audit/scripts/freeze.test.mjs
 */

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import {
    baseRemote,
    checkHead,
    freeze,
    intentText,
    localTimestamp,
    parseShortstat,
    pullRequestFrom,
    readTicket,
    ticketOfBranch,
} from './freeze.mjs';

const FACTS = {
    ticket: 'ABC-1',
    ticketSummary: 'Prüfung',
    branch: 'issue/ABC-1',
    base: 'develop',
    mergeBase: 'a'.repeat(40),
    head: 'b'.repeat(40),
    pr: 7,
    owner: 'owner',
    repo: 'repo',
};

test('the shortstat counts read as numbers, a part git omits as zero', () => {

    // Act
    const full = parseShortstat(' 74 files changed, 12141 insertions(+), 3574 deletions(-)');
    const single = parseShortstat(' 1 file changed, 1 insertion(+)');

    // Assert
    assert.deepEqual(full, {
        filesChanged: 74,
        additions: 12141,
        deletions: 3574,
    });
    assert.deepEqual(single, {
        filesChanged: 1,
        additions: 1,
        deletions: 0,
    });
});

test('the freeze time carries the local offset the renderer accepts', () => {

    // Arrange
    const date = new Date(2026, 8, 25, 9, 20, 11);
    const offset = -date.getTimezoneOffset();
    const expected = `${offset < 0 ? '-' : '+'}${String(Math.floor(Math.abs(offset) / 60)).padStart(2, '0')}:` +
        `${String(Math.abs(offset) % 60).padStart(2, '0')}`;

    // Act
    const stamp = localTimestamp(date);

    // Assert
    assert.equal(stamp, `2026-09-25T09:20:11${expected}`);
    assert.equal(Date.parse(stamp), date.getTime());
});

test('the ticket file gives key, summary and description, and a malformed heading stops the freeze', () => {

    // Arrange
    const dir = mkdtempSync(join(tmpdir(), 'pr-audit-freeze-'));
    const good = join(dir, 'ticket.md');
    const bad = join(dir, 'bad.md');

    try {
        writeFileSync(good, '\uFEFF# ABC-12: Größe prüfen\r\n\r\n### Aufgabe\r\n\r\nText.\r\n', 'utf8');
        writeFileSync(bad, 'ABC-12 Größe prüfen\n', 'utf8');

        // Act
        const ticket = readTicket(good);

        // Assert
        assert.deepEqual(ticket, {
            key: 'ABC-12',
            summary: 'Größe prüfen',
            description: '### Aufgabe\n\nText.',
        });
        assert.equal(readTicket(join(dir, 'missing.md')), null);
        assert.throws(() => readTicket(bad), /is not "# KEY-123: <summary>"/);
    } finally {
        rmSync(dir, {
            recursive: true,
            force: true,
        });
    }
});

test('a ticket of another branch\'s key is dropped, one on a branch without a key is kept', () => {

    // Arrange
    const ticket = {
        key: 'ABC-12',
        summary: 'Größe prüfen',
        description: 'Text.',
    };

    // Act and Assert
    assert.equal(ticketOfBranch(ticket, 'issue/ABC-12'), ticket);
    assert.equal(ticketOfBranch(ticket, 'issue/ABC-13'), null);
    assert.equal(ticketOfBranch(ticket, 'release/1.2.0'), ticket);
    assert.equal(ticketOfBranch(null, 'issue/ABC-12'), null);
});

test('intent.md holds the facts, the ticket and the pull request in the shape the fixtures have', () => {

    // Act
    const text = intentText(FACTS, {
        description: 'Beschreibung.',
    }, {
        title: '[ABC-1] Title',
        body: 'Body\r\nline.\r\n',
    });

    // Assert
    assert.equal(text, [
        '# Review context',
        '',
        '- ticket: ABC-1',
        '- summary: Prüfung',
        '- branch: issue/ABC-1',
        '- base: develop',
        `- merge-base: ${'a'.repeat(40)}`,
        `- head: ${'b'.repeat(40)}`,
        '- pr: 7',
        '- repository: owner/repo',
        '',
        '## Ticket description',
        '',
        'Beschreibung.',
        '',
        '## Pull request',
        '',
        '### [ABC-1] Title',
        '',
        'Body\nline.',
        '',
    ].join('\n'));
});

test('intent.md says so when there is no ticket and no pull request', () => {

    // Act
    const text = intentText({
        ...FACTS,
        ticket: null,
        ticketSummary: null,
        pr: null,
    }, null, null);

    // Assert
    assert.match(text, /^- ticket: none$/m);
    assert.match(text, /^- pr: none$/m);
    assert.match(text, /^The ticket could not be fetched/m);
    assert.match(text, /^## Pull request\n\nNo pull request exists\.\n$/m);
});

test('only gh saying there is no pull request means none; any other failure stops the freeze', () => {

    // Act
    const none = pullRequestFrom({
        status: 1,
        stdout: '',
        stderr: 'no pull requests found for branch "issue/ABC-1"',
    });
    const found = pullRequestFrom({
        status: 0,
        stdout: '{"number":7}',
        stderr: '',
    });

    // Assert
    assert.equal(none, null);
    assert.equal(found.number, 7);
    assert.throws(() => pullRequestFrom({
        status: 1,
        stdout: '',
        stderr: 'HTTP 401: Bad credentials',
    }), /gh pr view failed: HTTP 401/);
});

test('a HEAD GitHub may not have, or a reviewed file changed in the tree, stops the freeze', () => {

    // Arrange
    const pullRequest = {
        number: 7,
        headRefOid: 'b'.repeat(40),
    };

    // Act and Assert
    assert.throws(() => checkHead('c'.repeat(40), pullRequest, [], [], true), /head of pull request #7/);
    assert.throws(() => checkHead('b'.repeat(40), pullRequest, [
        'a.mjs',
    ], [
        'a.mjs',
        'b.mjs',
    ], true), /differs from HEAD in a\.mjs/);
    assert.throws(() => checkHead('c'.repeat(40), null, [], [], false), /on no remote branch; push it first/);
    checkHead('b'.repeat(40), pullRequest, [
        'other.mjs',
    ], [
        'a.mjs',
    ], true);
    checkHead('c'.repeat(40), null, [], [], true);
});

test('the base is fetched from the remote naming the pull request\'s repository, origin without one', () => {

    // Arrange
    const repository = {
        owner: 'ExampleOrg',
        repo: 'example_repo',
    };
    const remotes = [
        {
            name: 'origin',
            url: 'git@github.com:someone/example_repo.git',
        },
        {
            name: 'upstream',
            url: 'https://github.com/exampleorg/example_repo.git',
        },
    ];

    // Act and Assert
    assert.equal(baseRemote(remotes, repository), 'upstream');
    assert.equal(baseRemote(remotes.slice(0, 1), repository), 'origin');
    assert.equal(baseRemote([], repository), 'origin');
});

/**
 * Runs git in a directory and fails the test when git does.
 * @param cwd - The directory.
 * @param args - Its arguments.
 * @returns The trimmed stdout.
 */
function gitIn (cwd, ...args) {
    const result = spawnSync('git', args, {
        cwd,
        encoding: 'utf8',
    });

    assert.equal(result.status, 0, result.stderr);

    return result.stdout.trim();
}

test('the freeze writes git\'s own patch whatever the configuration, an umlaut path included, and empties the directory', () => {

    // Arrange
    const cwd = process.cwd();
    const base = mkdtempSync(join(tmpdir(), 'pr-audit-freeze-'));
    const repo = join(base, 'repo');
    const review = join(base, '.tmp', 'sessions', 's1', 'review');
    const commit = message => gitIn(
        repo,
        '-c',
        'user.name=t',
        '-c',
        'user.email=t@t',
        'commit',
        '--quiet',
        '--allow-empty',
        '--message',
        message
    );

    try {
        mkdirSync(repo);
        gitIn(repo, 'init', '--quiet');
        [
            'diff.noprefix=true',
            'color.diff=always',
            'diff.external=exit',
            'diff.suppressBlankEmpty=true',
            'diff.relative=true',
        ].forEach(setting => {
            const [
                key, value,
            ] = setting.split('=');

            gitIn(repo, 'config', key, value);
        });
        writeFileSync(join(repo, 'base.txt'), 'one\n\nkept\n', 'utf8');
        writeFileSync(join(repo, 'gone.txt'), 'old\n', 'utf8');
        gitIn(repo, 'add', '.');
        commit('base');

        const mergeBase = gitIn(repo, 'rev-parse', 'HEAD');

        writeFileSync(join(repo, 'base.txt'), 'two\n\nkept\n', 'utf8');
        writeFileSync(join(repo, 'ümlaut.txt'), 'new\n', 'utf8');
        rmSync(join(repo, 'gone.txt'));
        gitIn(repo, 'add', '--all', '.');
        commit('head');
        writeFileSync(join(base, 'fixture.json'), JSON.stringify({
            ...FACTS,
            head: gitIn(repo, 'rev-parse', 'HEAD'),
            mergeBase,
            filesChanged: 3,
            additions: 2,
            deletions: 2,
        }), 'utf8');
        writeFileSync(join(base, 'intent.md'), '# Review context\n', 'utf8');
        mkdirSync(review, {
            recursive: true,
        });
        [
            'ticket.md',
            'candidates-reviewer-3.json',
            'verified-2.json',
            'coverage.json',
        ].forEach(name => {
            writeFileSync(join(review, name), 'stale\n', 'utf8');
        });
        process.chdir(repo);

        // Act
        freeze(review, join(base, 'fixture.json'));

        // Assert
        const manifest = JSON.parse(readFileSync(join(review, 'manifest.json'), 'utf8'));

        const meta = JSON.parse(readFileSync(join(review, 'meta.json'), 'utf8'));

        assert.deepEqual(manifest.chunks.flatMap(chunk => chunk.files), [
            'base.txt',
            'gone.txt',
            'ümlaut.txt',
        ]);
        assert.equal(manifest.chunks.reduce((sum, chunk) => sum + chunk.changedLines, 0), 4);
        const patch = readFileSync(join(review, 'diff.patch'), 'utf8');

        assert.equal(patch.includes('\u001b'), false);
        assert.ok(patch.includes('+two\n \n kept\n'), 'a blank context line keeps its space');
        assert.equal(meta.mergeBase, mergeBase);
        assert.deepEqual(meta.deleted, [
            'gone.txt',
        ]);
        [
            'ticket.md',
            'candidates-reviewer-3.json',
            'verified-2.json',
            'coverage.json',
        ].forEach(name => {
            assert.equal(existsSync(join(review, name)), false, name);
        });
    } finally {
        process.chdir(cwd);
        rmSync(base, {
            recursive: true,
            force: true,
        });
    }
});

test('a fixture freeze refuses a tree dirty in a reviewed file, diff.relative and a subdirectory notwithstanding', () => {

    // Arrange
    const cwd = process.cwd();
    const base = mkdtempSync(join(tmpdir(), 'pr-audit-freeze-'));
    const repo = join(base, 'repo');
    const review = join(base, '.tmp', 'sessions', 's1', 'review');
    const commit = message => gitIn(
        repo,
        '-c',
        'user.name=t',
        '-c',
        'user.email=t@t',
        'commit',
        '--quiet',
        '--allow-empty',
        '--message',
        message
    );

    try {
        mkdirSync(join(repo, 'sub'), {
            recursive: true,
        });
        gitIn(repo, 'init', '--quiet');
        gitIn(repo, 'config', 'diff.relative', 'true');
        writeFileSync(join(repo, 'sub', 'keep.txt'), 'keep\n', 'utf8');
        gitIn(repo, 'add', '.');
        commit('base');

        const mergeBase = gitIn(repo, 'rev-parse', 'HEAD');

        writeFileSync(join(repo, 'top.txt'), 'committed\n', 'utf8');
        gitIn(repo, 'add', '.');
        commit('head');
        writeFileSync(join(repo, 'top.txt'), 'edited in the tree\n', 'utf8');
        writeFileSync(join(base, 'fixture.json'), JSON.stringify({
            ...FACTS,
            head: gitIn(repo, 'rev-parse', 'HEAD'),
            mergeBase,
        }), 'utf8');
        writeFileSync(join(base, 'intent.md'), '# Review context\n', 'utf8');
        process.chdir(join(repo, 'sub'));

        // Act and Assert
        assert.throws(() => freeze(review, join(base, 'fixture.json')), /differs from HEAD in top\.txt/);
        assert.equal(existsSync(join(review, 'diff.patch')), false);
    } finally {
        process.chdir(cwd);
        rmSync(base, {
            recursive: true,
            force: true,
        });
    }
});

const EARLIER_RUN = [
    'candidates-reviewer-1.json',
    'verified.json',
    'coverage.json',
];

/**
 * Builds a repository of two commits and a review directory holding an
 * earlier run, with a fixture naming the two commits.
 * @param base - The scratch root, which the test makes and removes, so that a
 * build that fails halfway leaves nothing behind.
 * @param headFiles - The files the head commit writes, by name.
 * @returns The repository, the review directory, the fixture and both commits.
 */
function earlierRunSetup (base, headFiles) {
    const repo = join(base, 'repo');
    const review = join(base, '.tmp', 'sessions', 's1', 'review');
    const commit = message => gitIn(
        repo,
        '-c',
        'user.name=t',
        '-c',
        'user.email=t@t',
        'commit',
        '--quiet',
        '--allow-empty',
        '--message',
        message
    );

    mkdirSync(repo);
    gitIn(repo, 'init', '--quiet');
    writeFileSync(join(repo, 'base.txt'), 'one\n', 'utf8');
    gitIn(repo, 'add', '.');
    commit('base');

    const mergeBase = gitIn(repo, 'rev-parse', 'HEAD');

    Object.entries(headFiles).forEach(([
        name,
        text,
    ]) => writeFileSync(join(repo, name), text, 'utf8'));
    gitIn(repo, 'add', '--all', '.');
    commit('head');

    const head = gitIn(repo, 'rev-parse', 'HEAD');
    const fixture = join(base, 'fixture.json');

    writeFileSync(fixture, JSON.stringify({
        ...FACTS,
        head,
        mergeBase,
        filesChanged: 1,
        additions: 1,
        deletions: 0,
    }), 'utf8');
    writeFileSync(join(base, 'intent.md'), '# Review context\n', 'utf8');
    mkdirSync(review, {
        recursive: true,
    });
    EARLIER_RUN.forEach(name => writeFileSync(join(review, name), 'earlier\n', 'utf8'));

    return {
        repo,
        review,
        fixture,
        mergeBase,
        head,
    };
}

/**
 * Asserts that every file of the earlier run is still in the review directory.
 * @param review - The review directory.
 */
function assertEarlierRunKept (review) {
    EARLIER_RUN.forEach(name => assert.equal(readFileSync(join(review, name), 'utf8'), 'earlier\n', name));
}

test('a freeze refused on HEAD, the tree or an empty diff leaves the earlier run in place', () => {

    // Arrange
    const cwd = process.cwd();
    const base = mkdtempSync(join(tmpdir(), 'pr-audit-freeze-'));
    const otherHead = join(base, 'other-head.json');
    const emptyDiff = join(base, 'empty-diff.json');

    try {
        const setup = earlierRunSetup(base, {
            'base.txt': 'two\n',
        });
        const fixture = JSON.parse(readFileSync(setup.fixture, 'utf8'));

        writeFileSync(otherHead, JSON.stringify({
            ...fixture,
            head: setup.mergeBase,
        }), 'utf8');
        writeFileSync(emptyDiff, JSON.stringify({
            ...fixture,
            mergeBase: setup.head,
        }), 'utf8');
        process.chdir(setup.repo);

        // Act and Assert
        assert.throws(() => freeze(setup.review, otherHead), /the fixture's head is/);
        assertEarlierRunKept(setup.review);
        assert.throws(() => freeze(setup.review, emptyDiff), /the diff is empty/);
        assertEarlierRunKept(setup.review);
        writeFileSync(join(setup.repo, 'base.txt'), 'edited in the tree\n', 'utf8');
        assert.throws(() => freeze(setup.review, setup.fixture), /differs from HEAD in base\.txt/);
        assertEarlierRunKept(setup.review);
        assert.equal(existsSync(join(setup.review, 'diff.patch')), false);
    } finally {
        process.chdir(cwd);
        rmSync(base, {
            recursive: true,
            force: true,
        });
    }
});

test('a review directory that links elsewhere is judged by its target and not emptied', () => {

    // Arrange
    const cwd = process.cwd();
    const base = mkdtempSync(join(tmpdir(), 'pr-audit-freeze-'));
    const elsewhere = join(base, 'source');
    const link = join(base, '.tmp', 'sessions', 's2', 'review');

    try {
        const setup = earlierRunSetup(base, {
            'base.txt': 'two\n',
        });

        mkdirSync(elsewhere);
        writeFileSync(join(elsewhere, 'kept.txt'), 'source\n', 'utf8');
        mkdirSync(join(link, '..'), {
            recursive: true,
        });
        symlinkSync(elsewhere, link, 'junction');
        process.chdir(setup.repo);

        // Act and Assert
        assert.throws(() => freeze(link, setup.fixture), /is not a review directory under \.tmp\/sessions/);
        assert.equal(readFileSync(join(elsewhere, 'kept.txt'), 'utf8'), 'source\n');
    } finally {
        process.chdir(cwd);
        rmSync(base, {
            recursive: true,
            force: true,
        });
    }
});

test('the freeze refuses a directory other than a review under .tmp/sessions/<id>/, since it empties it', () => {

    // Arrange
    const refused = [
        join(tmpdir(), 'not-a-review-dir'),
        join(tmpdir(), 'application', 'review'),
        join(tmpdir(), '.tmp', 'review'),
        join(tmpdir(), '.tmp', 'sessions', 'review'),
    ];

    // Act and Assert
    refused.forEach(dir => assert.throws(() => freeze(dir), /is not a review directory under \.tmp\/sessions/, dir));
});
