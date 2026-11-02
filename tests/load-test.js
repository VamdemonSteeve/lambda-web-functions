'use strict';

// Load / throttling test (SPEC 8.1).
// Fire N requests at /compute with bounded concurrency and report latency
// percentiles, success/throttle/reset/error counts, throughput and wall time.
//
// Usage:
//   node tests/load-test.js <base-url> [--count 1000] [--concurrency 50] [--n 64]
// Env:
//   RESULTS_DIR  if set, a JSON report is written there
//   TARGET       optional label (lambda|fargate|webfn) recorded in the report
//
// Retry note: a real client should retry HTTP 429 (throttle) responses with
// exponential backoff + jitter. This load test deliberately does NOT retry:
// retrying would mask the throttle counts this test exists to measure.
//
// For the webfn (native Lambda Web Function) target the throttling contract
// differs from classic Lambda: a 429 carries a `lambda-web-error-type` response
// header naming one of five throttle conditions, and an HTTP 503 with
// `lambda-web-error-type: Platform.EndpointDisabled` means the endpoint's
// rateLimit is 0 (a DISABLED endpoint, not a throttle).
// # TODO(webfn): confirm the five `lambda-web-error-type` throttle values.
// # TODO(webfn): confirm the `Platform.EndpointDisabled` 503 error-type value.
//
// Node 20 built-ins only.

const {
  request,
  percentile,
  mean,
  round,
  runPool,
  parseArgs,
  resolveResultsDir,
  writeReport,
} = require('./lib/util');
const { performance } = require('node:perf_hooks');

async function main() {
  const { _, flags } = parseArgs(process.argv.slice(2));
  const base = _[0] || process.env.BASE_URL;
  if (!base) {
    console.error(
      'usage: node tests/load-test.js <base-url> [--count 1000] [--concurrency 50] [--n 64]'
    );
    process.exit(2);
  }

  const count = parseInt(flags.count || process.env.COUNT || '1000', 10);
  const concurrency = parseInt(
    flags.concurrency || process.env.CONCURRENCY || '50',
    10
  );
  // Keep the per-request matrix small so the bottleneck is the platform
  // (concurrency/throttling), not a single huge computation.
  const n = parseInt(flags.n || process.env.MATRIX_N || '64', 10);
  const target = process.env.TARGET || flags.target || 'unknown';
  const isWebfn = target === 'webfn';

  const path = `/compute?n=${n}`;
  const latencies = [];
  let success = 0;
  let throttled = 0; // HTTP 429
  const throttleReasons = {}; // webfn only: lambda-web-error-type -> count
  let disabledEndpoint = 0; // webfn only: 503 Platform.EndpointDisabled
  let resets = 0; // ECONNRESET / socket hang up
  let otherErrors = 0;
  const errorSamples = [];

  console.log(
    `load-test: ${count} requests -> ${base}${path} (concurrency=${concurrency})`
  );

  const tasks = [];
  for (let i = 0; i < count; i++) {
    tasks.push(async () => {
      try {
        const res = await request(base, { path, timeoutMs: 30000 });
        latencies.push(res.totalMs);
        // util.request lowercases header names, so read the throttle/disabled
        // signal as `lambda-web-error-type`.
        const errType = res.headers['lambda-web-error-type'];
        if (res.statusCode === 429) {
          throttled += 1;
          if (isWebfn) {
            const reason = errType || 'unknown';
            throttleReasons[reason] = (throttleReasons[reason] || 0) + 1;
          }
        } else if (
          isWebfn &&
          res.statusCode === 503 &&
          errType === 'Platform.EndpointDisabled'
        ) {
          // Disabled endpoint (rateLimit=0), not a throttle and not an
          // otherError. A 503 WITHOUT this header stays an otherError below.
          disabledEndpoint += 1;
        } else if (res.statusCode >= 200 && res.statusCode < 400) {
          success += 1;
        } else {
          otherErrors += 1;
          if (errorSamples.length < 5) {
            errorSamples.push(`HTTP ${res.statusCode}`);
          }
        }
      } catch (err) {
        const code = err && err.code ? err.code : err.message;
        if (
          code === 'ECONNRESET' ||
          (typeof code === 'string' && code.includes('socket hang up'))
        ) {
          resets += 1;
        } else {
          otherErrors += 1;
        }
        if (errorSamples.length < 5) {
          errorSamples.push(String(code));
        }
      }
    });
  }

  const wallStart = performance.now();
  await runPool(tasks, concurrency);
  const wallMs = performance.now() - wallStart;

  const report = {
    test: 'load-test',
    target,
    baseUrl: base,
    path,
    count,
    concurrency,
    wallMs: round(wallMs),
    throughputReqPerSec: round(count / (wallMs / 1000)),
    success,
    throttled429: throttled,
    connectionResets: resets,
    otherErrors,
    errorSamples,
    // webfn-only fields are added below so the lambda/fargate report shape
    // stays byte-for-byte unchanged.
    latencyMs: {
      p50: round(percentile(latencies, 50)),
      p90: round(percentile(latencies, 90)),
      p99: round(percentile(latencies, 99)),
      mean: round(mean(latencies)),
      min: latencies.length ? round(Math.min(...latencies)) : 0,
      max: latencies.length ? round(Math.max(...latencies)) : 0,
    },
  };

  if (isWebfn) {
    report.throttleReasons = throttleReasons;
    report.disabledEndpoint = disabledEndpoint;
  }

  printReport(report);

  const resultsDir = resolveResultsDir(flags);
  const written = writeReport(resultsDir, 'load-test', report);
  if (written) {
    console.log(`report written: ${written}`);
  }
}

function printReport(r) {
  console.log('\n=== load-test results ===');
  console.log(`target:          ${r.target}`);
  console.log(`requests:        ${r.count} @ concurrency ${r.concurrency}`);
  console.log(`wall time:       ${r.wallMs} ms`);
  console.log(`throughput:      ${r.throughputReqPerSec} req/s`);
  console.log(`success:         ${r.success}`);
  console.log(`throttled (429): ${r.throttled429}`);
  console.log(`conn resets:     ${r.connectionResets}`);
  console.log(`other errors:    ${r.otherErrors}`);
  if (r.errorSamples.length) {
    console.log(`error samples:   ${r.errorSamples.join(', ')}`);
  }
  // webfn-only lines: present only when the webfn fields were added to the
  // report, so lambda/fargate output is byte-for-byte unchanged.
  if (r.throttleReasons !== undefined) {
    console.log(`throttle reasons:${JSON.stringify(r.throttleReasons)}`);
  }
  if (r.disabledEndpoint !== undefined) {
    console.log(`disabled (503):  ${r.disabledEndpoint}`);
  }
  console.log('latency (ms):');
  console.log(`  p50=${r.latencyMs.p50}  p90=${r.latencyMs.p90}  p99=${r.latencyMs.p99}`);
  console.log(`  mean=${r.latencyMs.mean}  min=${r.latencyMs.min}  max=${r.latencyMs.max}`);
}

main().catch((err) => {
  console.error('load-test failed:', err);
  process.exit(1);
});
