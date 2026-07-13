#!/usr/bin/env node
// npm entry shim for AgentKit.
//
// The toolkit is pure Bash and needs Bash >= 4.4 (macOS ships 3.2). This shim
// locates the packaged `bin/agent-kit` relative to its own real path (so it works
// through npm's bin symlinks), resolves a capable Bash, and hands off with the
// user's arguments and stdio.
'use strict';

const path = require('path');
const { spawnSync, execFileSync } = require('child_process');

const ai = path.join(__dirname, '..', 'bin', 'agent-kit');

// Return true if `bin` is a Bash >= 4.4.
function isCapableBash(bin) {
  if (!bin) return false;
  try {
    const out = execFileSync(
      bin,
      ['-c', 'printf "%s %s" "${BASH_VERSINFO[0]:-0}" "${BASH_VERSINFO[1]:-0}"'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }
    );
    const [maj, min] = out.trim().split(' ').map((n) => parseInt(n, 10));
    return maj > 4 || (maj === 4 && min >= 4);
  } catch (_) {
    return false;
  }
}

function resolveBash() {
  const candidates = [
    process.env.TOOL_BASH,
    '/opt/homebrew/bin/bash', // Homebrew on Apple Silicon
    '/usr/local/bin/bash', // Homebrew on Intel
    'bash', // whatever is first on PATH
    '/bin/bash',
  ];
  for (const c of candidates) {
    if (isCapableBash(c)) return c;
  }
  return null;
}

const bash = resolveBash();
if (!bash) {
  process.stderr.write(
    'agent-kit: requires Bash >= 4.4 (macOS ships 3.2).\n' +
      '  Install a newer Bash (e.g. `brew install bash`) or set TOOL_BASH=/path/to/bash.\n'
  );
  process.exit(127);
}

const result = spawnSync(bash, [ai, ...process.argv.slice(2)], {
  stdio: 'inherit',
});

if (result.error) {
  process.stderr.write(`agent-kit: ${result.error.message}\n`);
  process.exit(127);
}

process.exit(result.status === null ? 1 : result.status);
