'use strict';

// Cold start test (SPEC 8.4).
// Usage:
//   node tests/cold-start.js <lambda|fargate|webfn> <base-url> [--samples 20] [--burst 50]
// Env:
//   RESULTS_DIR  if set, a JSON report is written there
//
// lambda:  measure first (cold) vs subsequent (warm) request latency, then run
//          a burst and count how many landed on a cold environment via /info
//          coldStart. A single always-warm local server is handled gracefully.
// fargate: poll /health until ready and report boot-to-ready; against an
//          already-up server this is just first-request latency with a note
//          that there is no per-request cold start.
// webfn:   one warm execution environment serves many concurrent requests, so
//          cold-start frequency is not directly observable the way it is for
//          classic Lambda. Report firstRequestMs (init proxy) + steadyStateMs
//          over a warm /compute?n=64 burst; coldObservedViaInfo is conditional.
//
// Node 20 built-ins only.

const {
  request,
  percentile,
  round,
  runPool,
  sleep,
  parseArgs,
  resolveResultsDir,
  writeReport,
} = require('./lib/util');
const { performance } = require('node:perf_hooks');

async function pollHealthUntilReady(base, timeoutMs = 120000, intervalMs = 500) {
  const start = performance.now();
  let attempts = 0;
  while (performance.now() - start < timeoutMs) {
    attempts += 1;
    try {
      const res = await request(base, { path: '/health', timeoutMs: 5000 });
      if (res.statusCode === 200 && res.body.trim() === 'ok') {
        return { readyMs: round(performance.now() - start), attempts, ready: true };
      }
    } catch (err) {
      // not up yet
    }
    await sleep(intervalMs);
  }
  return { readyMs: round(performance.now() - start), attempts, ready: false };
}

/** Read the /info coldStart flag for a single request. */
async function probeColdStart(base) {
  const res = await request(base, { path: '/info', timeoutMs: 15000 });
  let coldStart = null;
  try {
    coldStart = JSON.parse(res.body).coldStart;
  } catch (err) {
    coldStart = null;
  }
  return { totalMs: res.totalMs, coldStart, statusCode: res.statusCode };
}

async function runFargate(base, flags) {
  console.log(`cold-start (fargate): polling ${base}/health for boot-to-ready`);
  const health = await pollHealthUntilReady(base);
  if (!health.ready) {
    console.log(`  WARN: /health not ready after polling (${health.readyMs} ms, ${health.attempts} attempts)`);
  }

  // First request latency after ready.
  const first = await request(base, { path: '/compute?n=64', timeoutMs: 30000 });
  const probe = await probeColdStart(base);

  const report = {
    test: 'cold-start',
    target: 'fargate',
    baseUrl: base,
    note:
      'Fargate has no per-request cold start; the finding is container boot-to-ready. Against an already-up server readyMs reflects only the first successful /health.',
    bootToReadyMs: health.readyMs,
    healthAttempts: health.attempts,
    firstRequestMs: round(first.totalMs),
    firstRequestColdStart: probe.coldStart,
  };

  console.log('\n=== cold-start (fargate) ===');
  console.log(`boot-to-ready:     ${report.bootToReadyMs} ms (${health.attempts} health checks)`);
  console.log(`first request:     ${report.firstRequestMs} ms`);
  console.log(`info.coldStart:    ${report.firstRequestColdStart}`);
  console.log(`note: ${report.note}`);

  return report;
}

async function runLambda(base, flags) {
  const samples = parseInt(flags.samples || '20', 10);
  const burst = parseInt(flags.burst || '50', 10);
  const concurrency = parseInt(flags.concurrency || '25', 10);

  console.log(`cold-start (lambda): ${samples} cold/warm pairs, burst of ${burst}`);

  const coldLatencies = [];
  const warmLatencies = [];
  let coldObserved = 0;

  // Each "pair" issues a request and inspects /info to learn whether the
  // serving process was cold. On a real Lambda, spacing requests out lets
  // environments recycle; against a local always-warm server everything is
  // warm after the very first request, which we report honestly.
  for (let i = 0; i < samples; i++) {
    const t0 = performance.now();
    const res = await request(base, { path: '/compute?n=64', timeoutMs: 30000 });
    const latency = performance.now() - t0;

    let coldStart = null;
    try {
      const info = await request(base, { path: '/info', timeoutMs: 15000 });
      coldStart = JSON.parse(info.body).coldStart;
    } catch (err) {
      coldStart = null;
    }

    // The very first request to a fresh process is the cold one. /info flips
    // the flag after the first request, so treat the first sample (or any
    // sample where /info still reports cold) as cold.
    if (i === 0 || coldStart === true) {
      coldLatencies.push(latency);
      coldObserved += 1;
    } else {
      warmLatencies.push(latency);
    }
    await sleep(100);
  }

  // Burst: count how many requests reported a cold start via /info.
  let burstCold = 0;
  let burstWarm = 0;
  let burstUnknown = 0;
  const burstTasks = [];
  for (let i = 0; i < burst; i++) {
    burstTasks.push(async () => {
      try {
        const info = await request(base, { path: '/info', timeoutMs: 15000 });
        const cold = JSON.parse(info.body).coldStart;
        if (cold === true) {
          burstCold += 1;
        } else if (cold === false) {
          burstWarm += 1;
        } else {
          burstUnknown += 1;
        }
      } catch (err) {
        burstUnknown += 1;
      }
    });
  }
  await runPool(burstTasks, concurrency);

  const localAlwaysWarm = coldObserved <= 1 && burstCold === 0;

  const report = {
    test: 'cold-start',
    target: 'lambda',
    baseUrl: base,
    samples,
    burst,
    coldCount: coldObserved,
    coldLatencyMs: {
      p50: round(percentile(coldLatencies, 50)),
      p99: round(percentile(coldLatencies, 99)),
    },
    warmLatencyMs: {
      p50: round(percentile(warmLatencies, 50)),
      p99: round(percentile(warmLatencies, 99)),
    },
    deltaP50Ms: round(
      percentile(coldLatencies, 50) - percentile(warmLatencies, 50)
    ),
    burstColdStarts: burstCold,
    burstWarm,
    burstUnknown,
    burstColdFraction: burst ? round((burstCold / burst) * 100, 1) : 0,
    note: localAlwaysWarm
      ? 'Target appears always-warm (likely a single local process). Only the first request was cold; no further cold starts observed. Run against a deployed Lambda Function URL for a real cold/warm distribution.'
      : 'Cold/warm distribution measured from /info coldStart flag.',
  };

  console.log('\n=== cold-start (lambda) ===');
  console.log(`cold observed:   ${report.coldCount}`);
  console.log(`cold latency:    p50=${report.coldLatencyMs.p50}  p99=${report.coldLatencyMs.p99} ms`);
  console.log(`warm latency:    p50=${report.warmLatencyMs.p50}  p99=${report.warmLatencyMs.p99} ms`);
  console.log(`delta (p50):     ${report.deltaP50Ms} ms`);
  console.log(`burst cold:      ${report.burstColdStarts}/${report.burst} (${report.burstColdFraction}%)`);
  console.log(`note: ${report.note}`);

  return report;
}

async function runWebfn(base, flags) {
  const samples = parseInt(flags.samples || '20', 10);
  const concurrency = parseInt(flags.concurrency || '25', 10);

  console.log(`cold-start (webfn): first-request init + ${samples}-request warm /compute?n=64 burst`);

  // firstRequestMs: latency of the very first request to a fresh/idle endpoint.
  // This is the PRIMARY metric and the best available proxy for init cost on a
  // native Web Function; it includes the init budget.
  // # TODO(webfn): confirm the init budget (documented as <=10s) against the docs.
  const t0 = performance.now();
  await request(base, { path: '/compute?n=64', timeoutMs: 30000 });
  const firstRequestMs = round(performance.now() - t0);

  // steadyStateMs: p50/p99 over a warm burst of /compute?n=64 run through
  // runPool. Modeled on runLambda's cold/warm SAMPLE loop (which also calls
  // /compute?n=64) -- NOT the burstTasks /info loop (that loop only counts cold
  // fractions and would record /info latency instead of compute latency).
  const warmLatencies = [];
  const warmTasks = [];
  for (let i = 0; i < samples; i++) {
    warmTasks.push(async () => {
      const r0 = performance.now();
      await request(base, { path: '/compute?n=64', timeoutMs: 30000 });
      warmLatencies.push(performance.now() - r0);
    });
  }
  await runPool(warmTasks, concurrency);

  // coldObservedViaInfo: CONDITIONAL. Counts /info probes reporting coldStart:true.
  // # TODO(webfn): confirm /info returns the app coldStart flag under the native
  // runtime and document its exact semantics (per env? per request?). If it is
  // NOT populated, drop coldObservedViaInfo and report only firstRequestMs +
  // steadyStateMs. Treat it strictly as a LOWER BOUND: one env serving N
  // concurrent requests reports cold at most once.
  let coldObservedViaInfo = 0;
  let infoColdPopulated = false;
  const infoTasks = [];
  for (let i = 0; i < samples; i++) {
    infoTasks.push(async () => {
      try {
        const info = await request(base, { path: '/info', timeoutMs: 15000 });
        const cold = JSON.parse(info.body).coldStart;
        if (cold === true || cold === false) {
          infoColdPopulated = true;
        }
        if (cold === true) {
          coldObservedViaInfo += 1;
        }
      } catch (err) {
        // ignore; the flag may not be populated under the native runtime
      }
    });
  }
  await runPool(infoTasks, concurrency);

  const report = {
    test: 'cold-start',
    target: 'webfn',
    baseUrl: base,
    samples,
    firstRequestMs,
    steadyStateMs: {
      p50: round(percentile(warmLatencies, 50)),
      p99: round(percentile(warmLatencies, 99)),
    },
    note:
      'Web Functions reuse one warm environment across concurrent requests; the app /info coldStart flag (if populated under the native runtime) marks only the first request a given environment serves, so cold-start frequency is not directly observable the way it is for classic Lambda. firstRequestMs is the primary proxy for init cost.',
  };

  // Only report coldObservedViaInfo when /info actually populated the flag; a
  // lower bound at best (see TODO above).
  if (infoColdPopulated) {
    report.coldObservedViaInfo = coldObservedViaInfo;
  }

  console.log('\n=== cold-start (webfn) ===');
  console.log(`first request:   ${report.firstRequestMs} ms (init proxy; includes init budget)`);
  console.log(`steady state:    p50=${report.steadyStateMs.p50}  p99=${report.steadyStateMs.p99} ms`);
  if (report.coldObservedViaInfo !== undefined) {
    console.log(`cold via /info:  ${report.coldObservedViaInfo} (lower bound)`);
  }
  console.log(`note: ${report.note}`);

  return report;
}

async function main() {
  const { _, flags } = parseArgs(process.argv.slice(2));
  const target = _[0];
  const base = _[1] || process.env.BASE_URL;
  if (!target || !['lambda', 'fargate', 'webfn'].includes(target) || !base) {
    console.error('usage: node tests/cold-start.js <lambda|fargate|webfn> <base-url> [--samples 20] [--burst 50]');
    process.exit(2);
  }

  let report;
  if (target === 'fargate') {
    report = await runFargate(base, flags);
  } else if (target === 'webfn') {
    report = await runWebfn(base, flags);
  } else {
    report = await runLambda(base, flags);
  }

  const resultsDir = resolveResultsDir(flags);
  const written = writeReport(resultsDir, 'cold-start', report);
  if (written) {
    console.log(`report written: ${written}`);
  }
}

main().catch((err) => {
  console.error('cold-start failed:', err);
  process.exit(1);
});
