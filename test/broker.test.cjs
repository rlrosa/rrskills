const { execFileSync, spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const repoRoot = path.resolve(__dirname, '..');
const scriptsDir = path.join(repoRoot, 'skills', 'paired-review-loop', 'scripts');
const session = path.join(scriptsDir, 'session.sh');
const roster = path.join(scriptsDir, 'roster.sh');
const broker = path.join(scriptsDir, 'broker.sh');

function hasTmux() {
  try {
    execFileSync('tmux', ['-V'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

if (!hasTmux()) {
  console.log('tmux is not installed; skipping broker tests.');
  process.exit(0);
}

// Every tmux command goes to a private server on a dedicated socket, so the
// test can create, type into and kill panes without any chance of touching a
// real session.  The panes run a fake agent (python3, so the pane's foreground
// command is not a shell) that echoes every line it receives: a line appearing
// in the pane history is proof the broker typed it in.
const socketName = `prl-broker-${process.pid}`;
const tmpDir = fs.mkdtempSync(path.join(repoRoot, 'test-tmp-'));

function tmux(args, opts = {}) {
  return execFileSync('tmux', ['-L', socketName, ...args], {
    encoding: 'utf8',
    ...opts,
  }).trim();
}

// Point child processes at the private server, exactly as they would be inside
// a pane of it.
let testEnv;
let socketPath;

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

function paneHistory(pane) {
  return tmux(['capture-pane', '-p', '-t', pane, '-S', '-400']);
}

function paneCommand(pane) {
  return tmux(['display-message', '-p', '-t', pane, '#{pane_current_command}']);
}

function waitForPaneCommand(pane, expected, timeoutMs = 10000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (paneCommand(pane) === expected) return;
    execFileSync('sleep', ['0.2']);
  }
  throw new Error(`pane ${pane} never became '${expected}' (still '${paneCommand(pane)}')`);
}

// Poll a pane's history until the regex matches; the history is the record of
// everything typed into the pane, so a match is proof of delivery.
function waitForPane(pane, regex, what, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (regex.test(paneHistory(pane))) return;
    execFileSync('sleep', ['0.5']);
  }
  throw new Error(`pane ${pane} never showed: ${what}\n--- history ---\n${paneHistory(pane)}`);
}

function waitForLog(sessionDir, regex, what, timeoutMs = 30000) {
  const logPath = path.join(sessionDir, 'broker', 'broker.log');
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(logPath) && regex.test(fs.readFileSync(logPath, 'utf8'))) return;
    execFileSync('sleep', ['0.5']);
  }
  throw new Error(`broker log never showed: ${what}\n--- log tail ---\n${tail(logPath, 40)}`);
}

function countMatches(text, regex) {
  return (text.match(new RegExp(regex.source, 'g')) || []).length;
}

function waitForPaneCount(pane, regex, expectedCount, what, timeoutMs = 90000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (countMatches(paneHistory(pane), regex) >= expectedCount) return;
    execFileSync('sleep', ['1']);
  }
  throw new Error(`pane ${pane} showed ${countMatches(paneHistory(pane), regex)} of ${expectedCount}: ${what}`);
}

function tail(file, lines) {
  try {
    return fs.readFileSync(file, 'utf8').split('\n').slice(-lines).join('\n');
  } catch {
    return '(no log)';
  }
}

function cleanup() {
  try {
    runScript(broker, ['stop', '--session', sessionDir]);
  } catch {
    // The broker may already be stopped; the server kill below is the real cleanup.
  }
  try {
    tmux(['kill-server'], { stdio: 'ignore' });
  } catch {
    // The server is already gone, which is the state we wanted anyway.
  }
  if (socketPath) fs.rmSync(socketPath, { force: true });
  fs.rmSync(tmpDir, { recursive: true, force: true });
}

// Fake agent: prints a ready line, then echoes every line it receives.
const fakeAgent = path.join(tmpDir, 'fake_agent.py');
fs.writeFileSync(
  fakeAgent,
  `import sys

label = sys.argv[1]
print(f"FAKE-AGENT {label} ready", flush=True)
for line in sys.stdin:
    print(f"GOT[{label}]: {line.rstrip()}", flush=True)
`,
);

// Fake agent that redraws for ~18s (a busy, mid-turn pane), then goes idle.
const fakeBusyAgent = path.join(tmpDir, 'fake_agent_busy.py');
fs.writeFileSync(
  fakeBusyAgent,
  `import sys
import time

for tick in range(60):
    sys.stdout.write(f"\\rBUSY {tick:02d}   ")
    sys.stdout.flush()
    time.sleep(0.3)
print("IDLE", flush=True)
for line in sys.stdin:
    print(f"GOT: {line.rstrip()}", flush=True)
`,
);

let sessionDir;
try {
  tmux([
    'new-session',
    '-d',
    '-s',
    'thinker',
    '-x',
    '160',
    '-y',
    '40',
    `python3 ${fakeAgent} thinker`,
  ]);
  const thinkerPaneId = tmux(['list-panes', '-t', 'thinker', '-F', '#{pane_id}']);
  socketPath = tmux(['display-message', '-p', '#{socket_path}']);
  testEnv = { ...process.env, TMUX: `${socketPath},0,0`, TMUX_PANE: thinkerPaneId };
  waitForPaneCommand(thinkerPaneId, 'python3');

  // One tmux session per worker pane so a replaced worker gets a fresh, known
  // pane without touching the first one until it is killed on purpose.
  function spawnWorkerPane(label) {
    const name = `worker-${label}`;
    tmux([
      'new-session',
      '-d',
      '-s',
      name,
      '-x',
      '160',
      '-y',
      '40',
      `python3 ${label === 'busy' ? fakeBusyAgent : fakeAgent} worker`,
    ]);
    const pane = tmux(['list-panes', '-t', name, '-F', '#{pane_id}']);
    waitForPaneCommand(pane, 'python3');
    return pane;
  }
  const workerPane = spawnWorkerPane('one');

  sessionDir = path.join(tmpDir, 'prl-broker');
  assert.strictEqual(runScript(session, ['init', sessionDir]).code, 0);
  assert.strictEqual(runScript(session, ['register', sessionDir, 'thinker']).code, 0);
  assert.strictEqual(
    runScript(roster, ['add', sessionDir, 'worker', 'worker', workerPane, tmpDir, 'python3 fake_agent.py worker']).code,
    0,
  );

  const inPath = path.join(sessionDir, 'members', 'worker', 'in');
  const outPath = path.join(sessionDir, 'members', 'worker', 'out');

  function startBroker() {
    const result = runScript(broker, ['start', '--session', sessionDir, '--socket', socketPath]);
    assert.strictEqual(result.code, 0, `broker start failed: ${result.stderr}`);
    waitForLog(sessionDir, /broker started/, 'broker startup line');
  }

  function stopBroker() {
    const result = runScript(broker, ['stop', '--session', sessionDir]);
    assert.strictEqual(result.code, 0, `broker stop failed: ${result.stderr}`);
  }

  // ------------------------------------------------------------------
  // 1. Normal two-way handoff: thinker writes in, the worker pane is woken;
  //    the worker writes out, the thinker pane is woken; the reply
  //    acknowledges the task.  An addendum that lands before the reply
  //    coalesces into a second wake naming both files, and the reply
  //    acknowledges it.
  // ------------------------------------------------------------------
  startBroker();
  fs.writeFileSync(inPath, 'task-1\n');
  const addendumPath = path.join(sessionDir, 'members', 'worker', 'in-addendum');
  waitForPane(
    workerPane,
    /GOT\[worker\]: prl: your inbox was updated - read .*\/members\/worker\/in$/,
    'the wake for in',
  );
  fs.writeFileSync(addendumPath, 'also do this\n');
  // The pane wraps long lines, so allow anything (including newlines) between
  // the two paths.
  waitForPane(
    workerPane,
    /GOT\[worker\]: prl: your inbox was updated - read [\s\S]*\/in then [\s\S]*in-addendum\n/,
    'the coalesced wake for in and in-addendum',
  );
  fs.writeFileSync(outPath, 'report-1\n');
  waitForLog(sessionDir, /worker: task acknowledged \(out is newer than in\)/, 'the ack of task-1');
  waitForPane(
    thinkerPaneId,
    /GOT\[thinker\]: prl: worker reported - read .*\/members\/worker\/out$/,
    'the wake for out',
  );
  console.log('ok 1 - two-way handoff wakes both panes');

  // ------------------------------------------------------------------
  // 2. Already-posted unread work is caught on broker startup: the broker is
  //    stopped, a new task lands in in, and the next start delivers it.
  // ------------------------------------------------------------------
  stopBroker();
  fs.writeFileSync(inPath, 'task-2\n');
  const workerWakeCount = countMatches(paneHistory(workerPane), /GOT\[worker\]: prl:/);
  startBroker();
  waitForPaneCount(workerPane, /GOT\[worker\]: prl:/, workerWakeCount + 1, 'the startup catch-up wake');
  console.log('ok 2 - existing unread file caught on startup');

  // ------------------------------------------------------------------
  // 3. Busy recipient: the worker pane is replaced by one that is mid-turn for
  //    ~18s.  The wake is deferred while it is busy and delivered once it goes
  //    idle, so the pending handoff is not lost.
  // ------------------------------------------------------------------
  const busyPane = spawnWorkerPane('busy');
  assert.strictEqual(
    runScript(roster, ['add', sessionDir, 'worker', 'worker', busyPane, tmpDir, 'python3 fake_agent_busy.py worker']).code,
    0,
  );
  tmux(['kill-pane', '-t', workerPane]);
  fs.writeFileSync(inPath, 'task-3\n');
  waitForLog(sessionDir, /defer wake for worker/, 'a deferral while the pane is busy');
  const busyWakeCount = 1; // the busy pane has seen nothing yet
  waitForPaneCount(busyPane, /GOT: prl: your inbox was updated/, busyWakeCount, 'the deferred wake after the pane went idle', 120000);
  console.log('ok 3 - busy recipient deferred, then picked up the pending handoff');

  // ------------------------------------------------------------------
  // 4. Closed pane: the worker pane is killed; the next write is skipped, the
  //    thinker is told the worker is unreachable, and the broker keeps running.
  // ------------------------------------------------------------------
  tmux(['kill-pane', '-t', busyPane]);
  fs.writeFileSync(inPath, 'task-4\n');
  waitForLog(sessionDir, /deregistered worker: pane \S+ closed/, 'the closed-pane deregistration');
  waitForPane(
    thinkerPaneId,
    /GOT\[thinker\]: prl: broker: worker is unreachable/,
    'the failure notice to the thinker',
  );
  assert.strictEqual(runScript(broker, ['status', '--session', sessionDir]).code, 0, 'broker should still be running');
  console.log('ok 4 - closed pane skipped, failure visible, broker alive');

  // ------------------------------------------------------------------
  // 5. Status reports running while up, not-running after stop.
  // ------------------------------------------------------------------
  stopBroker();
  assert.strictEqual(runScript(broker, ['status', '--session', sessionDir]).code, 1, 'broker should be stopped');
  console.log('ok 5 - stop and status agree');

  console.log('All broker tests passed.');
} finally {
  cleanup();
}