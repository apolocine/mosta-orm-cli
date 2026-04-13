#!/usr/bin/env node
// mostajs-launcher.cjs — cross-platform entry point for `mostajs` command
// Delegates to mostajs.sh on Unix, mostajs.bat on Windows.

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const isWin = os.platform() === 'win32';
const binDir = __dirname;
const script = isWin
  ? path.join(binDir, 'mostajs.bat')
  : path.join(binDir, 'mostajs.sh');

if (!fs.existsSync(script)) {
  console.error(`[mostajs] launcher error: ${script} not found.`);
  process.exit(1);
}

// Ensure executable on unix
if (!isWin) {
  try { fs.chmodSync(script, 0o755); } catch { /* ignore */ }
}

const args = process.argv.slice(2);
const child = isWin
  ? spawn('cmd', ['/c', script, ...args], { stdio: 'inherit', cwd: process.cwd() })
  : spawn('bash', [script, ...args], { stdio: 'inherit', cwd: process.cwd() });

child.on('exit', code => process.exit(code ?? 0));
child.on('error', err => {
  console.error('[mostajs] launch failed:', err.message);
  process.exit(1);
});
