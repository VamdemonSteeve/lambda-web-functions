'use strict';

// Time-to-first-byte / streaming test (SPEC 8.5).
// Hit GET /stream, measure TTFB separately from total transfer time, vary
// chunks/delay, report TTFB and total p50/p99 and the TTFB/total ratio, and
// flag streaming vs buffered (buffered when TTFB ~= total).
//
// Usage:
//   node tests/stream-ttfb.js <base-url> [--samples 20] [--chunks 10] [--delay 100]
// Env:
//   RESULTS_DIR  if set, a JSON report is written there
//   TARGET       optional label recorded in the report
//
// Node 20 built-ins only.

const {
  streamRequest,
  percentile,
  round,
  sleep,
  parseArgs,
  resolveResultsDir,
  writeReport,
} = require('./lib/util');

async function measure(base, chunks, delay, samples) {
  const ttfbs = [];
  const totals = [];
  const ratios = [];
  let firstColdTtfb = null;

  for (let i = 0; i < samples; i++) {
    const res = await streamRequest(base, {
      path: `/stream?chunks=${chunks}&delay=${delay}`,
      timeoutMs: 60000,
    });
    if (res.statusCode !== 200) {
      throw new Error(`/stream returned HTTP ${res.statusCode}`);
    }
    ttfbs.push(res.ttfbMs);
    totals.push(res.totalMs);
    ratios.push(res.totalMs > 0 ? res.ttfbMs / res.totalMs : 1);
    if (i === 0) {
      firstColdTtfb = res.ttfbMs;
    }
    await sleep(20);
  }

  return { ttfbs, totals, ratios, firstColdTtfb };
}

async function main() {
  const { _, flags } = parseArgs(process.argv.slice(2));
  const base = _[0] || process.env.BASE_URL;
  if (!base) {
    console.error('usage: node tests/stream-ttfb.js <base-url> [--samples 20] [--chunks 10] [--delay 100]');
    process.exit(2);
  }

  const samples = parseInt(flags.samples || '20', 10);
  const chunks = parseInt(flags.chunks || '10', 10);
  const delay = parseInt(flags.delay || '100', 10);
  const target = process.env.TARGET || flags.target || 'unknown';

  console.log(`stream-ttfb: GET ${base}/stream?chunks=${chunks}&delay=${delay}  samples=${samples}`);

  const { ttfbs, totals, ratios, firstColdTtfb } = await measure(base, chunks, delay, samples);

  const ttfbP50 = percentile(ttfbs, 50);
  const totalP50 = percentile(totals, 50);
  const ratioP50 = percentile(ratios, 50);

  // Buffered when the first byte arrives roughly together with the whole body.
  // Streaming when the first byte arrives well before the response completes.
  const buffered = ratioP50 >= 0.9;

  const report = {
    test: 'stream-ttfb',
    target,
    baseUrl: base,
    samples,
    chunks,
    delay,
    ttfbMs: {
      p50: round(ttfbP50),
      p99: round(percentile(ttfbs, 99)),
    },
    totalMs: {
      p50: round(totalP50),
      p99: round(percentile(totals, 99)),
    },
    ttfbTotalRatioP50: round(ratioP50, 3),
    mode: buffered ? 'buffered' : 'streaming',
    firstRequestTtfbMs: round(firstColdTtfb),
    note: buffered
      ? 'TTFB ~= total: response appears buffered (first byte withheld until complete).'
      : target === 'webfn'
      ? 'TTFB << total: native Lambda Web Function HTTP streaming (first byte arrives before completion), so mode: streaming is expected.'
      : 'TTFB << total: response is streamed (first byte arrives before completion).',
  };

  printReport(report);

  const resultsDir = resolveResultsDir(flags);
  const written = writeReport(resultsDir, 'stream-ttfb', report);
  if (written) {
    console.log(`report written: ${written}`);
  }
}

function printReport(r) {
  console.log('\n=== stream-ttfb results ===');
  console.log(`target:          ${r.target}`);
  console.log(`chunks/delay:    ${r.chunks} / ${r.delay} ms`);
  console.log(`TTFB (ms):       p50=${r.ttfbMs.p50}  p99=${r.ttfbMs.p99}`);
  console.log(`total (ms):      p50=${r.totalMs.p50}  p99=${r.totalMs.p99}`);
  console.log(`TTFB/total p50:  ${r.ttfbTotalRatioP50}`);
  console.log(`mode:            ${r.mode}`);
  console.log(`first-req TTFB:  ${r.firstRequestTtfbMs} ms (includes any cold-start init)`);
  console.log(`note: ${r.note}`);
}

main().catch((err) => {
  console.error('stream-ttfb failed:', err);
  process.exit(1);
});
