'use strict';

// Filesystem speed test (SPEC 8.2).
// POST /store with increasing payload sizes and report write/read ms and MB/s
// as measured by the app (/tmp on Lambda vs container ephemeral on Fargate).
//
// Usage:
//   node tests/fs-bench.js <base-url> [--sizes 1KB,64KB,1MB,8MB] [--repeat 3]
// Env:
//   RESULTS_DIR  if set, a JSON report is written there
//   TARGET       optional label recorded in the report
//
// Node 20 built-ins only.

const {
  request,
  mean,
  round,
  parseArgs,
  resolveResultsDir,
  writeReport,
} = require('./lib/util');

const DEFAULT_SIZES = ['1KB', '64KB', '1MB', '8MB'];

/** Parse a human size like '64KB' / '8MB' / '1024' into bytes. */
function parseSize(token) {
  const m = String(token)
    .trim()
    .match(/^(\d+(?:\.\d+)?)\s*(b|kb|mb|gb)?$/i);
  if (!m) {
    throw new Error(`invalid size: ${token}`);
  }
  const value = parseFloat(m[1]);
  const unit = (m[2] || 'b').toLowerCase();
  const mult = { b: 1, kb: 1024, mb: 1024 * 1024, gb: 1024 * 1024 * 1024 }[unit];
  return Math.round(value * mult);
}

async function main() {
  const { _, flags } = parseArgs(process.argv.slice(2));
  const base = _[0] || process.env.BASE_URL;
  if (!base) {
    console.error(
      'usage: node tests/fs-bench.js <base-url> [--sizes 1KB,64KB,1MB,8MB] [--repeat 3]'
    );
    process.exit(2);
  }

  const sizeTokens = (flags.sizes ? String(flags.sizes).split(',') : DEFAULT_SIZES)
    .map((s) => s.trim())
    .filter(Boolean);
  const repeat = parseInt(flags.repeat || process.env.REPEAT || '3', 10);
  const target = process.env.TARGET || flags.target || 'unknown';

  console.log(`fs-bench: POST ${base}/store  sizes=[${sizeTokens.join(', ')}]  repeat=${repeat}`);

  const rows = [];
  for (const token of sizeTokens) {
    const bytes = parseSize(token);
    const writeMs = [];
    const readMs = [];
    const writeMBps = [];
    const readMBps = [];
    let sizeBytes = bytes;

    for (let i = 0; i < repeat; i++) {
      const res = await request(base, {
        method: 'POST',
        path: `/store?size=${bytes}`,
        headers: { 'content-type': 'application/json' },
        timeoutMs: 60000,
      });
      if (res.statusCode !== 200) {
        throw new Error(`/store returned HTTP ${res.statusCode} for ${token}`);
      }
      const data = JSON.parse(res.body);
      writeMs.push(data.writeMs);
      readMs.push(data.readMs);
      writeMBps.push(data.writeMBps);
      readMBps.push(data.readMBps);
      sizeBytes = data.sizeBytes;
    }

    rows.push({
      size: token,
      sizeBytes,
      writeMs: round(mean(writeMs), 3),
      readMs: round(mean(readMs), 3),
      writeMBps: round(mean(writeMBps), 1),
      readMBps: round(mean(readMBps), 1),
    });
  }

  const report = {
    test: 'fs-bench',
    target,
    baseUrl: base,
    repeat,
    rows,
  };

  printTable(rows);

  const resultsDir = resolveResultsDir(flags);
  const written = writeReport(resultsDir, 'fs-bench', report);
  if (written) {
    console.log(`report written: ${written}`);
  }
}

function printTable(rows) {
  console.log('\n=== fs-bench results (mean over repeats) ===');
  const header = ['size', 'bytes', 'writeMs', 'readMs', 'writeMB/s', 'readMB/s'];
  const widths = [8, 10, 10, 10, 11, 11];
  const fmt = (cells) =>
    cells.map((c, i) => String(c).padStart(widths[i])).join('  ');
  console.log(fmt(header));
  console.log(fmt(widths.map((w) => '-'.repeat(w))));
  for (const r of rows) {
    console.log(
      fmt([r.size, r.sizeBytes, r.writeMs, r.readMs, r.writeMBps, r.readMBps])
    );
  }
}

main().catch((err) => {
  console.error('fs-bench failed:', err);
  process.exit(1);
});
