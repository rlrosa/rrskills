const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const repoRoot = path.resolve(__dirname, '..');
const installScript = path.join(repoRoot, 'install.sh');

// Create temporary directory for test environment
const tmpDir = fs.mkdtempSync(path.join(repoRoot, 'test-tmp-'));
const testClaudeDir = path.join(tmpDir, 'claude_skills');
const testAgyDir = path.join(tmpDir, 'agy_skills');
const testCodexDir = path.join(tmpDir, 'codex_skills');

const env = {
  ...process.env,
  CLAUDE_SKILLS_DIR: testClaudeDir,
  AGY_SKILLS_DIR: testAgyDir,
  CODEX_SKILLS_DIR: testCodexDir,
};

function cleanup() {
  if (fs.existsSync(tmpDir)) {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

try {
  console.log('Running test 1: Install all skills via symlink (default)...');
  const output1 = execSync(`"${installScript}"`, { env, encoding: 'utf8' });
  console.log(output1);

  assert(fs.existsSync(path.join(testClaudeDir, 'paired-review-loop')), 'Claude skill missing');
  assert(fs.existsSync(path.join(testAgyDir, 'paired-review-loop')), 'AGY skill missing');
  assert(fs.existsSync(path.join(testCodexDir, 'paired-review-loop')), 'Codex skill missing');

  assert(fs.lstatSync(path.join(testClaudeDir, 'paired-review-loop')).isSymbolicLink(), 'Claude skill should be symlink');
  assert(fs.lstatSync(path.join(testAgyDir, 'paired-review-loop')).isSymbolicLink(), 'AGY skill should be symlink');
  assert(fs.lstatSync(path.join(testCodexDir, 'paired-review-loop')).isSymbolicLink(), 'Codex skill should be symlink');

  console.log('Running test 2: List skills...');
  const outputList = execSync(`"${installScript}" -l`, { env, encoding: 'utf8' });
  assert(outputList.includes('Installed (Symlink'), 'List should show symlink status');

  console.log('Running test 3: Install for single target (claude) in copy mode...');
  execSync(`"${installScript}" -t claude -m copy -s paired-review-loop`, { env, encoding: 'utf8' });
  assert(!fs.lstatSync(path.join(testClaudeDir, 'paired-review-loop')).isSymbolicLink(), 'Claude skill should now be directory copy');
  assert(fs.lstatSync(path.join(testClaudeDir, 'paired-review-loop')).isDirectory(), 'Claude skill should be directory');

  console.log('Running test 4: Uninstall from all targets...');
  execSync(`"${installScript}" -u`, { env, encoding: 'utf8' });
  assert(!fs.existsSync(path.join(testClaudeDir, 'paired-review-loop')), 'Claude skill should be removed');
  assert(!fs.existsSync(path.join(testAgyDir, 'paired-review-loop')), 'AGY skill should be removed');
  assert(!fs.existsSync(path.join(testCodexDir, 'paired-review-loop')), 'Codex skill should be removed');

  console.log('All unit tests passed successfully!');
} catch (err) {
  cleanup();
  console.error('Test failed:', err);
  process.exit(1);
}

cleanup();
