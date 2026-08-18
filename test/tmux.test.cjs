const { execFileSync, spawnSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');

const repoRoot = path.resolve(__dirname, '..');
const scriptsDir = path.join(repoRoot, 'skills', 'paired-review-loop', 'scripts');
const notify = path.join(scriptsDir, 'notify.sh');
const watch = path.join(scriptsDir, 'watch.sh');
const session = path.join(scriptsDir, 'session.sh');

function hasTmux() {
  try {
    execFileSync('tmux', ['-V'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

if (!hasTmux()) {
  console.log('tmux is not installed; skipping tmux tests.');
  process.exit(0);
}

// Every tmux command in this file goes to a server of our own on a private
// socket, so the tests can create, type into and kill panes without any chance
// of touching the sessions the developer is actually working in.
const socketName = `prl-test-${process.pid}`;
const tmpDir = fs.mkdtempSync(path.join(repoRoot, 'test-tmp-'));

function tmux(args, opts = {}) {
  return execFileSync('tmux', ['-L', socketName, ...args], {
    encoding: 'utf8',
    ...opts,
  }).trim();
}

// Point child processes at our private server. The scripts call plain `tmux`,
// which resolves the server from $TMUX exactly as it would inside a real pane.
let testEnv;
let socketPath;

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

function paneCommand(pane) {
  return tmux(['display-message', '-p', '-t', pane, '#{pane_current_command}']);
}

// Wait for a pane's foreground command to become `expected`, so tests never
// race a shell that is still starting the program we asked for.
function waitForPaneCommand(pane, expected, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (paneCommand(pane) === expected) return;
    execFileSync('sleep', ['0.2']);
  }
  throw new Error(`pane ${pane} never became '${expected}' (still '${paneCommand(pane)}')`);
}

function cleanup() {
  try {
    tmux(['kill-server'], { stdio: 'ignore' });
  } catch {
    // The server is already gone, which is the state we wanted anyway.
  }
  // Killing the server leaves its socket file behind, so remove it too rather
  // than dropping a dead socket in /tmp on every run.
  if (socketPath) fs.rmSync(socketPath, { force: true });
  fs.rmSync(tmpDir, { recursive: true, force: true });
}

try {
  tmux(['new-session', '-d', '-s', 'prl', '-x', '160', '-y', '40', 'bash --norc --noprofile']);
  socketPath = tmux(['display-message', '-p', '#{socket_path}']);
  const thinkerPane = tmux(['list-panes', '-a', '-F', '#{pane_id}']).split('\n')[0];
  testEnv = { ...process.env, TMUX: `${socketPath},0,0`, TMUX_PANE: thinkerPane };

  // notify only addresses registered members now, so every case below needs a
  // session with this pane in it.
  const notifyDir = path.join(tmpDir, 'prl-notify');
  const roster = path.join(scriptsDir, 'roster.sh');
  runScript(session, ['init', notifyDir]);
  runScript(roster, ['add', notifyDir, 'peer', 'worker', thinkerPane, tmpDir, 'bash']);
  const toPeer = (message) => ['--session', notifyDir, '--member', 'peer', message];

  console.log('Running test 1: notify reports no reachable tmux server...');
  const noServer = runScript(notify, toPeer('prl: hi'), {
    TMUX: path.join(tmpDir, 'no-such-socket') + ',0,0',
  });
  assert.strictEqual(noServer.code, 10, 'unreachable server should exit 10');
  assert(noServer.stderr.includes('watch.sh'), 'should point the caller at the fallback');

  console.log('Running test 2: notify rejects a member it does not know...');
  const noPane = runScript(notify, ['--session', notifyDir, '--member', 'nobody', 'prl: hi']);
  assert.strictEqual(noPane.code, 1, 'an unregistered member should be rejected');

  console.log('Running test 3: notify refuses to type into a shell prompt...');
  // The pane is a bare shell, so a message that reaches it would be executed.
  // Send one that leaves a trace on disk, and prove no trace appears.
  const marker = path.join(tmpDir, 'guard-marker');
  assert.strictEqual(paneCommand(thinkerPane), 'bash', 'pane should be at a shell for this test');
  const guarded = runScript(notify, toPeer(`touch ${marker}`));
  assert.strictEqual(guarded.code, 12, 'shell prompt should exit 12');
  execFileSync('sleep', ['1']);
  assert(!fs.existsSync(marker), 'notify must not let a shell execute the message');
  assert(
    !tmux(['capture-pane', '-p', '-t', thinkerPane]).includes('guard-marker'),
    'notify must not type anything into a shell pane'
  );

  console.log('Running test 4: notify rejects a multi-line message...');
  const multiline = runScript(notify, toPeer('first line\nsecond line'));
  assert.strictEqual(multiline.code, 2, 'multi-line message should exit 2');

  console.log('Running test 5: notify delivers to a live pane...');
  // `cat` stands in for an agent TUI: it holds the foreground and echoes what
  // it is sent, so delivery is directly observable.
  tmux(['send-keys', '-t', thinkerPane, '-l', 'cat']);
  tmux(['send-keys', '-t', thinkerPane, 'Enter']);
  waitForPaneCommand(thinkerPane, 'cat');
  const message = 'prl: inbox updated - read /tmp/prl-demo/members/worker/in';
  const delivered = runScript(notify, toPeer(message));
  assert.strictEqual(delivered.code, 0, `delivery should exit 0, got ${delivered.code} ${delivered.stderr}`);
  assert(delivered.stdout.includes('DELIVERED'), 'should report delivery');
  assert(
    tmux(['capture-pane', '-p', '-t', thinkerPane]).includes(message),
    'the message should have reached the pane'
  );
  tmux(['send-keys', '-t', thinkerPane, 'C-c']);
  waitForPaneCommand(thinkerPane, 'bash');

  console.log('Running test 6: session.sh init/register/get...');
  const sessionDir = path.join(tmpDir, 'prl-session');
  runScript(session, ['init', sessionDir]);
  assert(fs.existsSync(path.join(sessionDir, 'members')), 'init should create members/');
  assert(fs.existsSync(path.join(sessionDir, 'roster.tsv')), 'init should create an empty roster');
  runScript(session, ['register', sessionDir, 'thinker']);
  // Registering twice must overwrite, not append a second conflicting line.
  runScript(session, ['register', sessionDir, 'thinker']);
  const envLines = fs
    .readFileSync(path.join(sessionDir, 'session.env'), 'utf8')
    .split('\n')
    .filter((line) => line.startsWith('PRL_THINKER_PANE='));
  assert.strictEqual(envLines.length, 1, 'repeated registration must not duplicate the key');
  const got = runScript(session, ['get', sessionDir, 'PRL_THINKER_PANE']);
  assert.strictEqual(got.stdout.trim(), thinkerPane, 'get should return the registered pane');
  assert.strictEqual(
    runScript(session, ['get', sessionDir, 'PRL_WORKER_PANE']).code,
    1,
    'get should exit 1 for an unset key'
  );

  console.log('Running test 7: watch.sh blocks until the file changes...');
  // Everything here runs synchronously in the foreground. Polling a spawned
  // child from this thread would not work: execFileSync blocks the event loop,
  // so the child's exit event could never be delivered while we waited for it.
  const watched = path.join(tmpDir, 'watched.out');
  fs.writeFileSync(watched, 'initial\n');

  // Still running when the timeout fires is the pass condition here: the
  // watcher is meant to sit there until something changes.
  let blocked = false;
  try {
    execFileSync(watch, [watched, '1'], { timeout: 3000, stdio: 'ignore' });
  } catch (err) {
    blocked = err.code === 'ETIMEDOUT';
  }
  assert(blocked, 'watcher must keep blocking while the file is untouched');

  // The touch has to land in a later whole second than the baseline the watcher
  // takes at startup, because mtime granularity here is one second.
  const watcherOut = execFileSync(
    'bash',
    ['-c', `( sleep 2; printf changed > "$1" ) & exec "$2" "$1" 1`, 'bash', watched, watch],
    { encoding: 'utf8', timeout: 20000 }
  );
  assert(watcherOut.includes('CHANGED'), 'watcher should report the change and exit 0');

  console.log('All tmux tests passed successfully!');
} catch (err) {
  cleanup();
  console.error('Test failed:', err);
  process.exit(1);
}

cleanup();
