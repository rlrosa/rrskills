const { execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');

const repoRoot = path.resolve(__dirname, '..');
const scriptsDir = path.join(repoRoot, 'skills', 'paired-review-loop', 'scripts');
const notify = path.join(scriptsDir, 'notify.sh');
const watch = path.join(scriptsDir, 'watch.sh');
const session = path.join(scriptsDir, 'session.sh');
const spawnWorker = path.join(scriptsDir, 'spawn-worker.sh');

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

function runScript(script, args, env = {}) {
  try {
    const stdout = execFileSync(script, args, {
      encoding: 'utf8',
      env: { ...testEnv, ...env },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    return { code: 0, stdout, stderr: '' };
  } catch (err) {
    return {
      code: err.status,
      stdout: err.stdout || '',
      stderr: err.stderr || '',
    };
  }
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

  console.log('Running test 1: notify reports no reachable tmux server...');
  const noServer = runScript(notify, [thinkerPane, 'prl: hi'], {
    TMUX: path.join(tmpDir, 'no-such-socket') + ',0,0',
  });
  assert.strictEqual(noServer.code, 10, 'unreachable server should exit 10');
  assert(noServer.stderr.includes('watch.sh'), 'should point the caller at the fallback');

  console.log('Running test 2: notify rejects an unknown pane...');
  const noPane = runScript(notify, ['%99999', 'prl: hi']);
  assert.strictEqual(noPane.code, 11, 'unknown pane should exit 11');

  console.log('Running test 3: notify refuses to type into a shell prompt...');
  // The pane is a bare shell, so a message that reaches it would be executed.
  // Send one that leaves a trace on disk, and prove no trace appears.
  const marker = path.join(tmpDir, 'guard-marker');
  assert.strictEqual(paneCommand(thinkerPane), 'bash', 'pane should be at a shell for this test');
  const guarded = runScript(notify, [thinkerPane, `touch ${marker}`]);
  assert.strictEqual(guarded.code, 12, 'shell prompt should exit 12');
  execFileSync('sleep', ['1']);
  assert(!fs.existsSync(marker), 'notify must not let a shell execute the message');
  assert(
    !tmux(['capture-pane', '-p', '-t', thinkerPane]).includes('guard-marker'),
    'notify must not type anything into a shell pane'
  );

  console.log('Running test 4: notify rejects a multi-line message...');
  const multiline = runScript(notify, [thinkerPane, 'first line\nsecond line']);
  assert.strictEqual(multiline.code, 2, 'multi-line message should exit 2');

  console.log('Running test 5: notify delivers to a live pane...');
  // `cat` stands in for an agent TUI: it holds the foreground and echoes what
  // it is sent, so delivery is directly observable.
  tmux(['send-keys', '-t', thinkerPane, '-l', 'cat']);
  tmux(['send-keys', '-t', thinkerPane, 'Enter']);
  waitForPaneCommand(thinkerPane, 'cat');
  const message = 'prl: worker.out updated - read /tmp/prl-demo/worker.out';
  const delivered = runScript(notify, [thinkerPane, message]);
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
  assert(fs.existsSync(path.join(sessionDir, 'evidence')), 'init should create evidence/');
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

  console.log('Running test 7: spawn-worker creates and bootstraps a pane...');
  const spawnDir = path.join(tmpDir, 'prl-spawn');
  fs.mkdirSync(spawnDir, { recursive: true });
  fs.writeFileSync(path.join(spawnDir, 'thinker.out'), 'TASK: prove you are alive\n');
  const spawned = runScript(spawnWorker, [
    '--session', spawnDir,
    '--cmd', 'cat',
    '--cwd', tmpDir,
  ]);
  assert.strictEqual(spawned.code, 0, `spawn should succeed, got ${spawned.code} ${spawned.stderr}`);
  const workerPane = spawned.stdout.trim();
  assert(/^%\d+$/.test(workerPane), `spawn should print a pane id, got '${workerPane}'`);
  assert.notStrictEqual(workerPane, thinkerPane, 'the worker must get its own pane');
  assert.strictEqual(paneCommand(workerPane), 'cat', 'the agent command should be running');

  const spawnEnv = fs.readFileSync(path.join(spawnDir, 'session.env'), 'utf8');
  assert(spawnEnv.includes(`PRL_THINKER_PANE='${thinkerPane}'`), 'session.env should record the thinker pane');
  assert(spawnEnv.includes(`PRL_WORKER_PANE='${workerPane}'`), 'session.env should record the worker pane');
  assert(spawnEnv.includes("PRL_WORKER_CMD='cat'"), 'session.env should record the worker command');

  // Strip the newlines the terminal inserts when it wraps the long bootstrap
  // line, so the text can be matched as it was written.
  const bootstrap = tmux(['capture-pane', '-p', '-t', workerPane]).replace(/\n/g, '');
  assert(bootstrap.includes('/paired-review-loop'), 'bootstrap should invoke the skill');
  assert(bootstrap.includes('You are the WORKER'), 'bootstrap should name the role');
  assert(bootstrap.includes(path.join(spawnDir, 'thinker.out')), 'bootstrap should point at the first task');

  // Typed is not the same as sent. A TUI that is still starting up echoes the
  // characters but drops the Enter, leaving the bootstrap parked in the input
  // box and the worker sitting there with no role. `cat` prints back each line
  // it receives, so a second copy on screen is proof the Enter took effect.
  const bootstrapCopies = bootstrap.split('You are the WORKER').length - 1;
  assert(
    bootstrapCopies >= 2,
    `bootstrap should be submitted, not left in the input box (saw ${bootstrapCopies} copies)`
  );

  console.log('Running test 8: spawn-worker honours the layout orientation...');
  // Check the geometry rather than trusting the flag was passed. tmux names a
  // side-by-side split "horizontal" and a stacked one "vertical", so a wired-up
  // -h/-v mix-up would still spawn a pane and still look like it worked.
  const paneGeometry = (pane) => {
    const [left, top] = tmux([
      'display-message', '-p', '-t', pane, '#{pane_left} #{pane_top}',
    ]).split(' ').map(Number);
    return { left, top };
  };

  // Read the thinker's position after each split, never before. A split can
  // move the original pane too — a configured pane border takes a row from
  // both — so a position measured beforehand is about a layout that no longer
  // exists.
  const spawnAndCompare = (dirName, layout) => {
    const sessionDir = path.join(tmpDir, dirName);
    const pane = runScript(spawnWorker, [
      '--session', sessionDir, '--cmd', 'cat', '--layout', layout, '--no-bootstrap',
    ]).stdout.trim();
    assert(/^%\d+$/.test(pane), `--layout ${layout} should print a pane id, got '${pane}'`);
    const geometry = { worker: paneGeometry(pane), thinker: paneGeometry(thinkerPane) };
    tmux(['kill-pane', '-t', pane]);
    return geometry;
  };

  const side = spawnAndCompare('prl-right', 'right');
  assert(side.worker.left > side.thinker.left, 'a "right" split should put the worker beside the thinker');
  assert.strictEqual(side.worker.top, side.thinker.top, 'a "right" split should not stack the panes');

  const stacked = spawnAndCompare('prl-below', 'below');
  assert(stacked.worker.top > stacked.thinker.top, 'a "below" split should put the worker under the thinker');
  assert.strictEqual(
    stacked.worker.left,
    stacked.thinker.left,
    'a "below" split should not put the panes side by side'
  );

  const belowDir = path.join(tmpDir, 'prl-below');

  assert.strictEqual(
    runScript(spawnWorker, ['--session', belowDir, '--cmd', 'cat', '--layout', 'sideways']).code,
    2,
    'an unknown layout should be rejected'
  );
  assert.strictEqual(
    runScript(spawnWorker, ['--session', belowDir, '--cmd', 'cat', '--size', '250']).code,
    2,
    'an out-of-range size should be rejected'
  );

  console.log('Running test 9: spawn-worker tells a worker to wait when there is no task yet...');
  const emptyDir = path.join(tmpDir, 'prl-empty');
  const spawnedEmpty = runScript(spawnWorker, ['--session', emptyDir, '--cmd', 'cat', '--layout', 'window']);
  assert.strictEqual(spawnedEmpty.code, 0, `spawn should succeed, got ${spawnedEmpty.stderr}`);
  const emptyPane = spawnedEmpty.stdout.trim();
  const waitText = tmux(['capture-pane', '-p', '-t', emptyPane]).replace(/\n/g, '');
  assert(waitText.includes('wait for its nudge'), 'a worker with no task must be told to wait');

  console.log('Running test 10: watch.sh blocks until the file changes...');
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
