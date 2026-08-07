const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const repoRoot = path.resolve(__dirname, '..');
const scriptsDir = path.join(repoRoot, 'skills', 'paired-review-loop', 'scripts');
const roster = path.join(scriptsDir, 'roster.sh');
const notify = path.join(scriptsDir, 'notify.sh');
const watch = path.join(scriptsDir, 'watch.sh');
const spawnTeam = path.join(scriptsDir, 'spawn-team.sh');

function hasTmux() {
  try {
    execFileSync('tmux', ['-V'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

if (!hasTmux()) {
  console.log('tmux is not installed; skipping roster tests.');
  process.exit(0);
}

// A server of our own on a private socket, so the tests can create, tag, type
// into and kill panes with no chance of touching real working sessions.
const socketName = `prl-test-roster-${process.pid}`;
const tmpDir = fs.mkdtempSync(path.join(repoRoot, 'test-tmp-'));

let testEnv;
let socketPath;

function tmux(args, opts = {}) {
  return execFileSync('tmux', ['-L', socketName, ...args], {
    encoding: 'utf8',
    ...opts,
  }).trim();
}

function runScript(script, args, env = {}) {
  try {
    const stdout = execFileSync(script, args, {
      encoding: 'utf8',
      env: { ...testEnv, ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return { code: 0, stdout, stderr: '' };
  } catch (err) {
    return { code: err.status, stdout: err.stdout || '', stderr: err.stderr || '' };
  }
}

function paneTag(pane, tag) {
  return tmux(['display-message', '-p', '-t', pane, `#{@${tag}}`]);
}

function cleanup() {
  try {
    tmux(['kill-server'], { stdio: 'ignore' });
  } catch {
    // Already gone, which is the state we wanted.
  }
  if (socketPath) fs.rmSync(socketPath, { force: true });
  fs.rmSync(tmpDir, { recursive: true, force: true });
}

try {
  tmux(['new-session', '-d', '-s', 'prl', '-x', '200', '-y', '60', 'bash --norc --noprofile']);
  socketPath = tmux(['display-message', '-p', '#{socket_path}']);
  const thinkerPane = tmux(['list-panes', '-a', '-F', '#{pane_id}']).split('\n')[0];
  testEnv = { ...process.env, TMUX: `${socketPath},0,0`, TMUX_PANE: thinkerPane };

  console.log('Running test 1: roster add/get/list round trip...');
  const sessionDir = path.join(tmpDir, 'prl-roster');
  runScript(roster, ['init', sessionDir]);
  const paneB = tmux(['split-window', '-d', '-t', thinkerPane, '-P', '-F', '#{pane_id}']);
  const paneC = tmux(['split-window', '-d', '-t', thinkerPane, '-P', '-F', '#{pane_id}']);

  runScript(roster, ['add', sessionDir, 'worker', 'worker', thinkerPane, tmpDir, 'claude --model sonnet']);
  runScript(roster, ['add', sessionDir, 'tester-1', 'tester', paneB, tmpDir, 'codex']);
  runScript(roster, ['add', sessionDir, 'tester-2', 'tester', paneC, tmpDir, 'agy --dangerously-skip-permissions']);

  assert.strictEqual(
    runScript(roster, ['get', sessionDir, 'worker', 'agent']).stdout.trim(),
    'claude --model sonnet',
    'an agent command with spaces and flags must survive the round trip'
  );
  assert.strictEqual(
    runScript(roster, ['list', sessionDir, 'tester']).stdout.trim().split('\n').length,
    2,
    'listing a role should return only that role'
  );
  assert(
    fs.existsSync(path.join(sessionDir, 'members', 'tester-1', 'evidence')),
    'adding a member should create its mailbox and evidence dir'
  );
  // Re-adding must replace the row, not leave two rows claiming one name.
  runScript(roster, ['add', sessionDir, 'tester-1', 'tester', paneB, tmpDir, 'codex --search']);
  const rows = fs
    .readFileSync(path.join(sessionDir, 'roster.tsv'), 'utf8')
    .split('\n')
    .filter((line) => line.startsWith('tester-1\t'));
  assert.strictEqual(rows.length, 1, 're-adding a member must overwrite its row');

  console.log('Running test 2: a deleted roster is rebuilt from the panes...');
  fs.rmSync(path.join(sessionDir, 'roster.tsv'));
  const synced = runScript(roster, ['sync', sessionDir]);
  assert.strictEqual(synced.code, 0, `sync should succeed: ${synced.stderr}`);
  assert.strictEqual(
    runScript(roster, ['get', sessionDir, 'tester-2', 'agent']).stdout.trim(),
    'agy --dangerously-skip-permissions',
    'sync must recover the full agent command, not just the binary name'
  );
  assert.strictEqual(
    runScript(roster, ['get', sessionDir, 'tester-2', 'pane']).stdout.trim(),
    paneC,
    'sync must put each member back in its own pane'
  );

  console.log('Running test 3: resolve refuses a pane that belongs to someone else...');
  assert.strictEqual(
    runScript(roster, ['resolve', sessionDir, 'tester-1']).stdout.trim(),
    paneB,
    'resolve should return the pane while the tag agrees'
  );
  tmux(['set-option', '-p', '-t', paneB, '@prl_member', 'somebody-else']);
  assert.strictEqual(
    runScript(roster, ['resolve', sessionDir, 'tester-1']).code,
    14,
    'a pane tagged for another member must be refused'
  );
  const verified = runScript(roster, ['verify', sessionDir]);
  assert(verified.stdout.includes('MISMATCH  tester-1'), 'verify should name the mismatched member');
  assert(verified.stdout.includes('UNLISTED  somebody-else'), 'verify should name the unexpected occupant');
  tmux(['set-option', '-p', '-t', paneB, '@prl_member', 'tester-1']);

  console.log('Running test 4: resolve reports a pane that has been closed...');
  tmux(['kill-pane', '-t', paneC]);
  assert.strictEqual(
    runScript(roster, ['resolve', sessionDir, 'tester-2']).code,
    11,
    'a closed pane should be reported as gone, not as a mismatch'
  );
  assert.strictEqual(
    runScript(roster, ['resolve', sessionDir, 'nobody']).code,
    1,
    'an unknown member should exit 1'
  );

  console.log('Running test 5: notify --member refuses to send to the wrong agent...');
  // `cat` stands in for an agent TUI: it holds the foreground and echoes what it
  // is sent, so both delivery and non-delivery are directly observable.
  tmux(['send-keys', '-t', paneB, '-l', 'cat']);
  tmux(['send-keys', '-t', paneB, 'Enter']);
  execFileSync('sleep', ['1']);
  const goodSend = runScript(notify, ['--session', sessionDir, '--member', 'tester-1', 'prl: inbox updated']);
  assert.strictEqual(goodSend.code, 0, `a correctly addressed nudge should land: ${goodSend.stderr}`);

  tmux(['set-option', '-p', '-t', paneB, '@prl_member', 'somebody-else']);
  const wrongSend = runScript(notify, [
    '--session', sessionDir, '--member', 'tester-1', 'prl: MUST-NOT-ARRIVE',
  ]);
  assert.strictEqual(wrongSend.code, 14, 'a stale roster entry must not deliver');
  execFileSync('sleep', ['1']);
  assert(
    !tmux(['capture-pane', '-p', '-t', paneB]).includes('MUST-NOT-ARRIVE'),
    'nothing may be typed into a pane whose identity does not match'
  );
  tmux(['set-option', '-p', '-t', paneB, '@prl_member', 'tester-1']);

  console.log('Running test 6: spawn-team builds a tagged, tiled team...');
  const teamDir = path.join(tmpDir, 'prl-team');
  const spec = path.join(tmpDir, 'team.txt');
  fs.writeFileSync(
    spec,
    '# name      role     agent\nworker      worker   cat\ntester-1    tester   cat\ntester-2    tester   cat\n'
  );
  const team = runScript(spawnTeam, ['--session', teamDir, '--spec', spec, '--cwd', tmpDir]);
  assert.strictEqual(team.code, 0, `spawn-team should succeed: ${team.stderr}`);

  const spawned = team.stdout.trim().split('\n').map((line) => line.split('\t'));
  assert.strictEqual(spawned.length, 3, 'every member in the spec should be spawned');
  const teamWindows = new Set();
  for (const [name, pane] of spawned) {
    assert.strictEqual(paneTag(pane, 'prl_member'), name, `${name}'s pane should be tagged`);
    assert.strictEqual(paneTag(pane, 'prl_session'), teamDir, `${name} should be tagged for this session`);
    teamWindows.add(tmux(['display-message', '-p', '-t', pane, '#{window_id}']));
  }
  assert.strictEqual(teamWindows.size, 1, 'the team should be gathered into one window');
  assert.strictEqual(
    tmux(['display-message', '-p', '-t', spawned[0][1], '#{window_name}']),
    'prl-team',
    'the window should be named after the session, without doubling the prefix'
  );
  assert.strictEqual(
    runScript(roster, ['list', teamDir]).stdout.trim().split('\n').length,
    3,
    'the roster should list the whole team'
  );

  console.log('Running test 7: --role rings every tester and no one else...');
  const broadcast = runScript(notify, ['--session', teamDir, '--role', 'tester', 'prl: run the suite']);
  assert.strictEqual(broadcast.code, 0, `broadcast should reach both testers: ${broadcast.stderr}`);
  assert.strictEqual(
    broadcast.stdout.trim().split('\n').length,
    2,
    'a role broadcast should report once per member'
  );
  const workerPane = runScript(roster, ['get', teamDir, 'worker', 'pane']).stdout.trim();
  assert(
    !tmux(['capture-pane', '-p', '-t', workerPane]).includes('run the suite'),
    'a tester broadcast must not reach the worker'
  );

  console.log('Running test 8: a placeholder in the input box does not block a send...');
  // Agent TUIs draw a greyed-out suggestion in an empty input box. Anything
  // that reads the screen to decide whether the box is free sees that text and
  // refuses to send. The cursor is what distinguishes them, so stand up a pane
  // showing text the cursor is NOT sitting behind and prove a nudge still lands.
  const ghostPane = tmux(['split-window', '-d', '-t', thinkerPane, '-P', '-F', '#{pane_id}']);
  tmux(['send-keys', '-t', ghostPane, '-l', "printf 'Write tests for @filename\\r'; cat"]);
  tmux(['send-keys', '-t', ghostPane, 'Enter']);
  execFileSync('sleep', ['1']);

  const ghostScreen = tmux(['capture-pane', '-p', '-t', ghostPane]);
  const ghostCursorColumn = Number(tmux(['display-message', '-p', '-t', ghostPane, '#{cursor_x}']));
  assert(ghostScreen.includes('Write tests for @filename'), 'the pane should show placeholder-like text');
  assert.strictEqual(ghostCursorColumn, 0, 'the cursor must stay at the start despite the visible text');

  runScript(roster, ['add', sessionDir, 'ghost', 'tester', ghostPane, tmpDir, 'cat']);
  const ghostSend = runScript(notify, [
    '--session', sessionDir, '--member', 'ghost', 'prl: sent past the placeholder',
  ]);
  assert.strictEqual(ghostSend.code, 0, `a placeholder must not block delivery: ${ghostSend.stderr}`);
  assert(
    tmux(['capture-pane', '-p', '-t', ghostPane]).includes('prl: sent past the placeholder'),
    'the message should have reached the pane'
  );
  // Typed and sent are different things: `cat` echoes a line only once the
  // Enter is delivered, so a second copy is proof the submit half worked.
  const ghostCopies = tmux(['capture-pane', '-p', '-t', ghostPane])
    .split('prl: sent past the placeholder').length - 1;
  assert(ghostCopies >= 2, `the message should be submitted, not parked (saw ${ghostCopies} copies)`);
  tmux(['kill-pane', '-t', ghostPane]);

  console.log('Running test 9: watch.sh returns on whichever mailbox changes...');
  // The thinker waits on every member at once when there is no tmux, so a
  // change to any one of them has to end the wait — not only the first listed.
  const outFiles = ['worker', 'tester-1', 'tester-2'].map((name) => {
    const file = path.join(teamDir, 'members', name, 'out');
    fs.writeFileSync(file, 'initial\n');
    return file;
  });
  const watched = execFileSync(
    'bash',
    ['-c', '( sleep 2; printf changed > "$1" ) & exec "$2" "$3" "$4" "$1" --interval 1',
      'bash', outFiles[2], watch, outFiles[0], outFiles[1]],
    { encoding: 'utf8', timeout: 20000 }
  );
  assert(
    watched.includes(`CHANGED ${outFiles[2]}`),
    `watch should report the file that actually changed, got: ${watched}`
  );

  console.log('All roster tests passed successfully!');
} catch (err) {
  cleanup();
  console.error('Test failed:', err);
  process.exit(1);
}

cleanup();
