const { execFileSync, spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const repoRoot = path.resolve(__dirname, '..');
const scriptsDir = path.join(repoRoot, 'skills', 'paired-review-loop', 'scripts');
const roster = path.join(scriptsDir, 'roster.sh');
const notify = path.join(scriptsDir, 'notify.sh');
const watch = path.join(scriptsDir, 'watch.sh');
const status = path.join(scriptsDir, 'status.sh');

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

// spawnSync rather than execFileSync: these scripts warn on stderr while still
// succeeding, and execFileSync only hands back stderr when the command fails.
function runScript(script, args, env = {}) {
  const result = spawnSync(script, args, {
    encoding: 'utf8',
    env: { ...testEnv, ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return {
    code: result.status,
    stdout: result.stdout || '',
    stderr: result.stderr || '',
  };
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

  console.log('Running test 6: a human-created pane is registered and briefed...');
  // The skill no longer makes panes. The human makes one, hands over its ID,
  // and registering it is what puts it within reach at all.
  const teamDir = path.join(tmpDir, 'prl-team');
  runScript(roster, ['init', teamDir]);
  // A window of its own, so the panes are wide enough to read back what was
  // typed into them. In the crowded shared window they end up a few columns
  // across, and the briefing is then unverifiable rather than absent.
  const teamHost = tmux(['new-window', '-d', '-P', '-F', '#{pane_id}']);
  const handedOver = {};
  for (const [name, role] of [['worker', 'worker'], ['tester-1', 'tester'], ['tester-2', 'tester']]) {
    const pane = tmux(['split-window', '-d', '-t', teamHost, '-P', '-F', '#{pane_id}']);
    tmux(['send-keys', '-t', pane, '-l', 'cat']);
    tmux(['send-keys', '-t', pane, 'Enter']);
    handedOver[name] = pane;
    const added = runScript(roster, ['add', teamDir, name, role, pane, tmpDir, 'cat']);
    assert.strictEqual(added.code, 0, `registering ${name} should succeed: ${added.stderr}`);
    assert.strictEqual(paneTag(pane, 'prl_member'), name, `${name}'s pane should be tagged`);
    assert.strictEqual(paneTag(pane, 'prl_session'), teamDir, `${name} should be tagged for this session`);
  }
  execFileSync('sleep', ['1']);
  assert.strictEqual(
    runScript(roster, ['list', teamDir]).stdout.trim().split('\n').length,
    3,
    'the roster should list every registered member'
  );

  // Briefing types the role into the pane the human handed over.
  fs.writeFileSync(path.join(teamDir, 'members', 'worker', 'in'), 'TASK: prove you are alive\n');
  const briefed = runScript(roster, ['brief', teamDir, 'worker']);
  assert.strictEqual(briefed.code, 0, `brief should succeed: ${briefed.stderr}`);
  const briefText = tmux(['capture-pane', '-p', '-t', handedOver.worker]).replace(/\n/g, '');
  assert(briefText.includes('You are the WORKER'), 'the briefing should name the role');
  assert(
    briefText.includes(path.join(teamDir, 'members', 'worker', 'in')),
    'the briefing should point at the first task'
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

  console.log('Running test 10: watch.sh gives up at its deadline...');
  // An unbounded wait is what turns a lost nudge into a permanent stall, so the
  // deadline firing is the property that matters most here.
  const idleFile = path.join(tmpDir, 'nobody-writes-here');
  fs.writeFileSync(idleFile, 'initial\n');
  const timedOut = runScript(watch, [idleFile, '--interval', '1', '--timeout', '3']);
  // Exit 0: reaching the deadline is a normal end to a wait, and a non-zero code
  // made every harness announce a failure that had not happened.
  assert.strictEqual(timedOut.code, 0, 'a deadline passing is not an error');
  assert(timedOut.stdout.startsWith('TIMEOUT'), 'the outcome is told by the first word of stdout');

  // A change inside the window still wins; the deadline must not mask it.
  const beatsDeadline = execFileSync(
    'bash',
    ['-c', '( sleep 2; printf changed > "$1" ) & exec "$2" "$1" --interval 1 --timeout 20',
      'bash', idleFile, watch],
    { encoding: 'utf8', timeout: 30000 }
  );
  assert(beatsDeadline.includes('CHANGED'), 'a change inside the window should still report CHANGED');

  // The escape hatch has to keep working, or anyone relying on it silently
  // starts getting woken every 900s.
  let stillBlocking = false;
  try {
    execFileSync(watch, [idleFile, '--interval', '1', '--timeout', '0'], { timeout: 4000, stdio: 'ignore' });
  } catch (err) {
    stillBlocking = err.code === 'ETIMEDOUT';
  }
  assert(stillBlocking, '--timeout 0 should still wait indefinitely');

  console.log('Running test 11: status.sh says whose move it is...');
  const turnDir = path.join(tmpDir, 'prl-turns');
  runScript(roster, ['init', turnDir]);
  const turnPane = tmux(['split-window', '-d', '-t', thinkerPane, '-P', '-F', '#{pane_id}']);
  tmux(['send-keys', '-t', turnPane, '-l', 'cat']);
  tmux(['send-keys', '-t', turnPane, 'Enter']);
  execFileSync('sleep', ['1']);
  runScript(roster, ['add', turnDir, 'worker', 'worker', turnPane, tmpDir, 'cat']);

  const memberInbox = path.join(turnDir, 'members', 'worker', 'in');
  const memberOutbox = path.join(turnDir, 'members', 'worker', 'out');

  // Nothing written at all: the thinker owes the first task.
  let report = runScript(status, [turnDir]);
  assert(/worker\s+thinker/.test(report.stdout), `expected thinker to owe first, got:\n${report.stdout}`);

  // Task written, no reply: the member owes.
  fs.writeFileSync(memberInbox, 'TASK\n');
  report = runScript(status, [turnDir]);
  assert(/worker\s+worker/.test(report.stdout), `expected the member to owe, got:\n${report.stdout}`);

  // Reply written after the task: the thinker owes again. The sleep is real —
  // mtime has one-second granularity, so a same-second reply is indistinguishable.
  execFileSync('sleep', ['1']);
  fs.writeFileSync(memberOutbox, 'REPORT\n');
  report = runScript(status, [turnDir]);
  assert(/worker\s+thinker/.test(report.stdout), `expected the thinker to owe again, got:\n${report.stdout}`);

  // Fresh moves are fine; only an old one needs attention.
  assert.strictEqual(
    runScript(status, [turnDir], { PRL_STALL_AFTER: '600' }).code,
    0,
    'a move seconds old should not be flagged'
  );
  assert.strictEqual(
    runScript(status, [turnDir], { PRL_STALL_AFTER: '0' }).code,
    1,
    'a move older than the threshold should be flagged'
  );

  console.log('Running test 12: a glob that matches nothing yet still catches the reply...');
  // The thinker's idiom is watch.sh '<dir>/members/*/out'. On round one no out
  // file exists, so the shell has nothing to expand and passes the literal '*'
  // through as a filename that can never appear. Seen live: the worker reported
  // and the thinker slept through it until its deadline.
  const globDir = path.join(tmpDir, 'prl-glob');
  fs.mkdirSync(path.join(globDir, 'members', 'worker'), { recursive: true });
  const globPattern = path.join(globDir, 'members', '*', 'out');
  const lateReply = path.join(globDir, 'members', 'worker', 'out');

  const caughtLateFile = execFileSync(
    'bash',
    ['-c', '( sleep 2; printf report > "$1" ) & exec "$2" "$3" --interval 1 --timeout 15',
      'bash', lateReply, watch, globPattern],
    { encoding: 'utf8', timeout: 30000 }
  );
  assert(
    caughtLateFile.includes(`CHANGED ${lateReply}`),
    `a report written after the watcher armed must wake it, got: ${caughtLateFile}`
  );

  // And a member who joins mid-wait has to be picked up too, which a one-shot
  // expansion at launch could never do.
  const joiner = path.join(globDir, 'members', 'tester-1', 'out');
  const caughtNewMember = execFileSync(
    'bash',
    ['-c', 'rm -f "$1"; ( sleep 2; mkdir -p "$(dirname "$4")"; printf hi > "$4" ) & exec "$2" "$3" --interval 1 --timeout 15',
      'bash', lateReply, watch, globPattern, joiner],
    { encoding: 'utf8', timeout: 30000 }
  );
  assert(
    caughtNewMember.includes(`CHANGED ${joiner}`),
    `a member joining mid-wait must wake the thinker, got: ${caughtNewMember}`
  );

  console.log('Running test 13: a pane too narrow to verify says so, and still sends...');
  // A one-column pane is where this bit hardest: the agent in it stayed alive
  // and looked reachable while every nudge failed with "may still be starting
  // up", which sent the diagnosis in entirely the wrong direction.
  // Build it in a window of its own. Resizing a pane inside the shared test
  // window is silently clamped by whatever else is laid out there, which would
  // leave this "narrow" pane comfortably wide and the test proving nothing.
  const narrowHost = tmux(['new-window', '-d', '-P', '-F', '#{pane_id}']);
  const narrowPane = tmux(['split-window', '-h', '-d', '-t', narrowHost, '-P', '-F', '#{pane_id}']);
  tmux(['send-keys', '-t', narrowPane, '-l', 'cat']);
  tmux(['send-keys', '-t', narrowPane, 'Enter']);
  execFileSync('sleep', ['1']);
  tmux(['resize-pane', '-t', narrowPane, '-x', '10']);
  execFileSync('sleep', ['1']);
  const narrowWidth = Number(tmux(['display-message', '-p', '-t', narrowPane, '#{pane_width}']));
  assert(narrowWidth < 40, `the pane must actually be narrow for this test, got ${narrowWidth}`);

  // Register it, because that is now the only way a pane can be addressed.
  const narrowDir = path.join(tmpDir, 'prl-narrow');
  runScript(roster, ['init', narrowDir]);
  runScript(roster, ['add', narrowDir, 'squeezed', 'tester', narrowPane, tmpDir, 'cat']);
  const narrowSend = runScript(notify, [
    '--session', narrowDir, '--member', 'squeezed', 'prl: narrow probe',
  ]);
  assert.strictEqual(narrowSend.code, 0, 'a narrow pane should still be sent to, not abandoned');
  assert(
    /columns wide/.test(narrowSend.stdout),
    `it must name the width as the reason it cannot confirm, got: ${narrowSend.stdout}`
  );
  assert(
    !/starting up/.test(narrowSend.stdout + narrowSend.stderr),
    'it must not blame startup for a width problem'
  );
  tmux(['kill-window', '-t', narrowHost]);

  console.log('Running test 14: no script can create, destroy or reshape a pane...');
  // A structural guarantee rather than a behavioural one. The rule is that the
  // human owns the terminal layout, so the check is that the capability is
  // simply absent from the source — no test of behaviour can prove that a
  // script will never split a window, but grepping for the verbs can.
  const forbidden = [
    'split-window', 'new-window', 'new-session',
    'kill-pane', 'kill-window', 'kill-server',
    'resize-pane', 'select-layout', 'break-pane', 'join-pane', 'swap-pane',
  ];
  for (const script of fs.readdirSync(scriptsDir).filter((f) => f.endsWith('.sh'))) {
    const body = fs.readFileSync(path.join(scriptsDir, script), 'utf8');
    for (const verb of forbidden) {
      assert(
        !body.includes(`tmux ${verb}`),
        `${script} must not be able to run 'tmux ${verb}' - the human owns the pane layout`
      );
    }
  }

  console.log('Running test 15: an unregistered pane cannot be reached at all...');
  const strangerPane = tmux(['split-window', '-d', '-t', thinkerPane, '-P', '-F', '#{pane_id}']);
  tmux(['send-keys', '-t', strangerPane, '-l', 'cat']);
  tmux(['send-keys', '-t', strangerPane, 'Enter']);
  execFileSync('sleep', ['1']);

  // There is no argument that names a raw pane, so this cannot even be asked.
  const byPane = runScript(notify, [strangerPane, 'prl: MUST-NOT-ARRIVE']);
  assert.strictEqual(byPane.code, 2, 'notify must not accept a bare pane ID');
  assert(/roster\.sh add/.test(byPane.stderr), 'it should say registration is the only way in');

  const byName = runScript(notify, ['--session', teamDir, '--member', 'stranger', 'prl: MUST-NOT-ARRIVE']);
  assert.strictEqual(byName.code, 1, 'an unregistered name should be rejected');
  execFileSync('sleep', ['1']);
  assert(
    !tmux(['capture-pane', '-p', '-t', strangerPane]).includes('MUST-NOT-ARRIVE'),
    'nothing may reach a pane the human never registered'
  );
  tmux(['kill-pane', '-t', strangerPane]);

  console.log('Running test 16: an unreachable tmux says WHY, and says to carry on...');
  // Told only "no tmux server reachable", a thinker stopped a session and asked
  // its human to restore tmux — while tmux was running and the real error was
  // a sandbox refusing the socket. Both halves of that mistake are tested: the
  // reason has to be named, and the loop has to be described as still fine.
  const blockedSocket = path.join(tmpDir, 'blocked.sock');
  execFileSync('python3', ['-c',
    `import socket, os\ns = socket.socket(socket.AF_UNIX)\ns.bind(${JSON.stringify(blockedSocket)})\ns.listen(1)\nos.chmod(${JSON.stringify(blockedSocket)}, 0)`]);

  const sandboxed = runScript(notify, ['--session', teamDir, '--member', 'worker', 'prl: hi'], {
    TMUX: `${blockedSocket},0,0`,
  });
  assert.strictEqual(sandboxed.code, 10, 'an unreachable tmux should exit 10');
  assert(/sandbox/i.test(sandboxed.stderr), `it should name the sandbox: ${sandboxed.stderr}`);
  assert(
    /IS running/.test(sandboxed.stderr),
    'it should say tmux is running, so nobody goes off restarting it'
  );
  assert(
    /does NOT block the loop/.test(sandboxed.stderr),
    'it must say the session can continue without the poke'
  );
  fs.rmSync(blockedSocket, { force: true });

  // A genuinely absent server must read differently, or the diagnosis is
  // decorative.
  const noServer = runScript(notify, ['--session', teamDir, '--member', 'worker', 'prl: hi'], {
    TMUX: `${path.join(tmpDir, 'nothing-here')},0,0`,
  });
  assert.strictEqual(noServer.code, 10, 'a missing server should also exit 10');
  assert(
    /no tmux server is running/.test(noServer.stderr),
    `a missing server should not be reported as a sandbox: ${noServer.stderr}`
  );

  console.log('All roster tests passed successfully!');
} catch (err) {
  cleanup();
  console.error('Test failed:', err);
  process.exit(1);
}

cleanup();
