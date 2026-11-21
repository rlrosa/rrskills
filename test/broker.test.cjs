const { execFileSync, spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const repoRoot = path.resolve(__dirname, '..');
const scriptsDir = path.join(repoRoot, 'skills', 'paired-review-loop', 'scripts');
const session = path.join(scriptsDir, 'session.sh');
const roster = path.join(scriptsDir, 'roster.sh');
const broker = path.join(scriptsDir, 'broker.sh');
const ack = path.join(scriptsDir, 'ack.sh');
const registerAgent = path.join(scriptsDir, 'register-agent.sh');

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

// Like waitForLog, but for a line that may already have appeared: wait until
// it has appeared at least expectedCount times.
function waitForLogCount(sessionDir, regex, expectedCount, what, timeoutMs = 60000) {
  const logPath = path.join(sessionDir, 'broker', 'broker.log');
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const text = fs.existsSync(logPath) ? fs.readFileSync(logPath, 'utf8') : '';
    if (countMatches(text, regex) >= expectedCount) return;
    execFileSync('sleep', ['0.5']);
  }
  throw new Error(
    `broker log showed ${countMatches(fs.existsSync(logPath) ? fs.readFileSync(logPath, 'utf8') : '', regex)} of ${expectedCount}: ${what}\n--- log tail ---\n${tail(logPath, 60)}`
  );
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

// Fake agent: prints a ready line, writes its own pid to the file named in
// argv[2] (how a real agent registers itself), then echoes every line it
// receives.  The OCCUPY line makes it leave unsent text on the input line
// (cursor parked past the guard's empty-input column) and stop reading,
// simulating a pane with a human's draft in the box.
const fakeAgent = path.join(tmpDir, 'fake_agent.py');
fs.writeFileSync(
  fakeAgent,
  `import os
import sys
import time

label = sys.argv[1]
pidfile = sys.argv[2]
with open(pidfile, "w") as handle:
    handle.write(str(os.getpid()))
print(f"FAKE-AGENT {label} ready", flush=True)
for line in sys.stdin:
    line = line.rstrip()
    print(f"GOT[{label}]: {line}", flush=True)
    if line == "OCCUPY":
        sys.stdout.write("input: unsent draft")
        sys.stdout.flush()
        break
time.sleep(3600)
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
    `python3 ${fakeAgent} thinker ${path.join(tmpDir, 'thinker.pid')}`,
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
      `python3 ${label === 'busy' ? fakeBusyAgent : fakeAgent} worker ${path.join(tmpDir, 'worker-' + label + '.pid')}`,
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
  const addendumPath = path.join(sessionDir, 'members', 'worker', 'in-addendum');

  function startBroker(env = {}) {
    const result = runScript(broker, ['start', '--session', sessionDir, '--socket', socketPath], env);
    assert.strictEqual(result.code, 0, `broker start failed: ${result.stderr}`);
    waitForLog(sessionDir, /broker started/, 'broker startup line');
  }

  function stopBroker() {
    const result = runScript(broker, ['stop', '--session', sessionDir]);
    assert.strictEqual(result.code, 0, `broker stop failed: ${result.stderr}`);
  }

  const statusOutput = () => runScript(broker, ['status', '--session', sessionDir]).stdout;

  // ------------------------------------------------------------------
  // 1. Normal two-way handoff: thinker writes in, the worker pane is woken;
  //    the worker writes out, the thinker pane is woken.  An addendum that
  //    lands before the ack coalesces into a second wake naming both files.
  // ------------------------------------------------------------------
  startBroker();
  fs.writeFileSync(inPath, 'task-1\n');
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
  waitForPane(
    thinkerPaneId,
    /GOT\[thinker\]: prl: worker reported - read .*\/members\/worker\/out$/,
    'the wake for out',
  );
  console.log('ok 1 - two-way handoff wakes both panes');

  // ------------------------------------------------------------------
  // 2. Explicit acks.  The thinker reads and acks the final report: the
  //    pending wake is removed WITHOUT another in being posted.  A newer
  //    report re-arms the wake, so a stale ack does not suppress it; the
  //    member side acks its task the same way.
  // ------------------------------------------------------------------
  assert.strictEqual(runScript(ack, [sessionDir, 'worker', 'out']).code, 0, 'ack.sh out');
  waitForLog(sessionDir, /worker: report acknowledged/, 'the ack of the final report');
  assert(
    statusOutput().includes('wake->thinker -'),
    `the thinker wake should be cleared by the ack, got: ${statusOutput()}`,
  );
  fs.writeFileSync(outPath, 'report-2\n');
  waitForLogCount(sessionDir, /worker: pending wake to thinker/, 2, 'the re-armed wake for report-2');
  assert.strictEqual(runScript(ack, [sessionDir, 'worker', 'out']).code, 0, 'ack.sh out again');
  waitForLogCount(sessionDir, /worker: report acknowledged/, 2, 'the ack of report-2');

  fs.writeFileSync(inPath, 'task-ack\n');
  const workerWakeCount = countMatches(paneHistory(workerPane), /GOT\[worker\]: prl:/);
  waitForPaneCount(workerPane, /GOT\[worker\]: prl:/, workerWakeCount + 1, 'the wake for task-ack');
  assert.strictEqual(runScript(ack, [sessionDir, 'worker', 'in']).code, 0, 'ack.sh in');
  // The addendum from scenario 1 is still owed a read, so it needs its own
  // ack before the member wake can clear.
  assert.strictEqual(runScript(ack, [sessionDir, 'worker', 'in-addendum']).code, 0, 'ack.sh in-addendum');
  waitForLog(sessionDir, /worker: task acknowledged/, 'the member ack of its task');
  assert(
    statusOutput().includes('wake->member -'),
    `the member wake should be cleared by the ack, got: ${statusOutput()}`,
  );
  console.log('ok 2 - acks remove pending work; a stale ack does not suppress a newer revision');

  // ------------------------------------------------------------------
  // 3. Already-posted unread work is caught on broker startup: the broker is
  //    stopped, a new task lands in in (unacked), and the next start
  //    delivers it.
  // ------------------------------------------------------------------
  stopBroker();
  fs.writeFileSync(inPath, 'task-2\n');
  const catchUpCount = countMatches(paneHistory(workerPane), /GOT\[worker\]: prl:/);
  startBroker();
  waitForPaneCount(workerPane, /GOT\[worker\]: prl:/, catchUpCount + 1, 'the startup catch-up wake');
  console.log('ok 3 - existing unread file caught on startup');

  // ------------------------------------------------------------------
  // 4. Busy recipient: the worker pane is replaced by one that is mid-turn
  //    for ~18s.  The wake is deferred while it is busy and delivered once
  //    it goes idle, so the pending handoff is not lost.
  // ------------------------------------------------------------------
  const busyPane = spawnWorkerPane('busy');
  assert.strictEqual(
    runScript(roster, ['add', sessionDir, 'worker', 'worker', busyPane, tmpDir, 'python3 fake_agent_busy.py worker']).code,
    0,
  );
  tmux(['kill-pane', '-t', workerPane]);
  fs.writeFileSync(inPath, 'task-3\n');
  waitForLog(sessionDir, /defer wake for worker/, 'a deferral while the pane is busy');
  waitForPaneCount(busyPane, /GOT: prl: your inbox was updated/, 1, 'the deferred wake after the pane went idle', 120000);
  console.log('ok 4 - busy recipient deferred, then picked up the pending handoff');

  // ------------------------------------------------------------------
  // 5. Closed pane: the worker pane is killed; the next write is skipped, the
  //    thinker is told the worker is unreachable, and the broker keeps
  //    running.
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
  console.log('ok 5 - closed pane skipped, failure visible, broker alive');

  // ------------------------------------------------------------------
  // 6. Guarded re-nudges and guarded delivery into an occupied pane.  The
  //    broker runs with a 5s ack window (PRL_BROKER_ACK_TIMEOUT_SECONDS) so
  //    the re-nudge fires quickly.  Once the pane holds unsent text, neither
  //    the re-nudge nor a re-armed initial delivery may type into it.
  // ------------------------------------------------------------------
  stopBroker();
  const occupiedPane = spawnWorkerPane('occ');
  assert.strictEqual(
    runScript(roster, ['add', sessionDir, 'worker', 'worker', occupiedPane, tmpDir, 'python3 fake_agent.py worker']).code,
    0,
  );
  startBroker({ PRL_BROKER_ACK_TIMEOUT_SECONDS: '5' });
  // The unacked task from scenario 5 is still in the mailbox, so the new pane
  // first gets a catch-up wake for it.  Only then is the input line occupied
  // and the guards exercised.
  waitForPaneCount(occupiedPane, /GOT\[worker\]: prl:/, 1, 'the catch-up wake for the unacked task');
  fs.writeFileSync(inPath, 'task-rn\n');
  waitForPaneCount(occupiedPane, /GOT\[worker\]: prl:/, 2, 'the wake while the input line is free');
  tmux(['send-keys', '-t', occupiedPane, 'OCCUPY', 'Enter']);
  // The 5s ack window elapses first; the re-nudge must be held back by the
  // guard, not typed.  Only then is the wake re-armed with a newer task, so
  // the initial-delivery path is exercised separately.
  waitForLogCount(sessionDir, /defer re-nudge for worker: input line occupied/, 1, 'the deferred re-nudge', 60000);
  // A newer task re-arms the wake; the initial delivery path must also refuse.
  fs.writeFileSync(inPath, 'task-rn2\n');
  waitForLogCount(sessionDir, /defer wake for worker: input line occupied/, 1, 'the guarded initial delivery');
  assert.strictEqual(
    countMatches(paneHistory(occupiedPane), /GOT\[worker\]: prl:/),
    2,
    'catch-up and one wake only; nothing new may be typed into a pane with unsent input',
  );
  console.log('ok 6 - re-nudges and deliveries honor the occupied-input guard');

  // ------------------------------------------------------------------
  // 7. Explicit agent identity: the worker runs inside an open shell.  With
  //    the actual agent process registered, the broker wakes it; after the
  //    agent dies and a new process of the same binary takes its place, the
  //    registered identity no longer matches, so nothing is typed and the
  //    thinker is told.
  // ------------------------------------------------------------------
  // Clear the pending wake from scenario 6 so no delivery can land in this
  // scenario's pane before the identity checks begin.
  assert.strictEqual(runScript(ack, [sessionDir, 'worker', 'in']).code, 0, 'clear the pending wake');
  waitForLogCount(sessionDir, /worker: task acknowledged/, 2, 'the clear of scenario 6\'s pending wake');
  tmux(['new-session', '-d', '-s', 'worker-shell', '-x', '160', '-y', '40', 'bash --norc --noprofile']);
  const shellPane = tmux(['list-panes', '-t', 'worker-shell', '-F', '#{pane_id}']);
  waitForPaneCommand(shellPane, 'bash');
  tmux(['send-keys', '-t', shellPane, `python3 ${fakeAgent} worker ${path.join(tmpDir, 'shell-agent.pid')}`, 'Enter']);
  waitForPaneCommand(shellPane, 'python3');
  assert.strictEqual(
    runScript(roster, ['add', sessionDir, 'worker', 'worker', shellPane, tmpDir, 'python3 fake_agent.py worker']).code,
    0,
  );
  const agentPidFile = path.join(tmpDir, 'shell-agent.pid');
  let agentPidA = '';
  const pidDeadline = Date.now() + 10000;
  while (!agentPidA && Date.now() < pidDeadline) {
    try {
      agentPidA = fs.readFileSync(agentPidFile, 'utf8').trim();
    } catch {}
    if (!agentPidA) execFileSync('sleep', ['0.2']);
  }
  assert.ok(agentPidA, 'the agent should write its own pid');
  assert.strictEqual(runScript(registerAgent, [sessionDir, 'worker', agentPidA]).code, 0, 'register-agent.sh');
  fs.writeFileSync(inPath, 'task-id-A\n');
  waitForPaneCount(shellPane, /GOT\[worker\]: prl: your inbox was updated/, 1, 'the wake while agent A is registered');
  // Ack so no re-nudge can fire while the agent is killed and restarted.
  assert.strictEqual(runScript(ack, [sessionDir, 'worker', 'in']).code, 0, 'ack task-id-A');
  // Agent A dies back to the shell; agent B (same binary) starts in its place.
  execFileSync('kill', [agentPidA]);
  waitForPaneCommand(shellPane, 'bash');
  tmux(['send-keys', '-t', shellPane, `python3 ${fakeAgent} worker ${path.join(tmpDir, 'shell-agent.pid')}`, 'Enter']);
  waitForPaneCommand(shellPane, 'python3');
  fs.writeFileSync(inPath, 'task-id-B\n');
  waitForLog(sessionDir, /deregistered worker: registered agent/, 'the agent identity invalidation');
  assert.strictEqual(
    countMatches(paneHistory(shellPane), /GOT\[worker\]: prl:/),
    1,
    'nothing may be typed once the registered agent is gone',
  );
  const thinkerNoticeCount = countMatches(paneHistory(thinkerPaneId), /GOT\[thinker\]: prl: broker: worker is unreachable/);
  waitForPaneCount(thinkerPaneId, /GOT\[thinker\]: prl: broker: worker is unreachable/, thinkerNoticeCount + 1, 'the identity failure notice');
  console.log('ok 7 - registered agent identity invalidates a restarted agent in the same pane');

  // ------------------------------------------------------------------
  // 8. Status reports running while up, not-running after stop.
  // ------------------------------------------------------------------
  stopBroker();
  assert.strictEqual(runScript(broker, ['status', '--session', sessionDir]).code, 1, 'broker should be stopped');
  console.log('ok 8 - stop and status agree');

  console.log('All broker tests passed.');
} finally {
  cleanup();
}