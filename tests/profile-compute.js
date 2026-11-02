'use strict';

// Compute profiling test (SPEC 8.3).
// Run the app's compute.multiply in-process under the node:inspector CPU
// profiler across a few MATRIX_SIZE values, write a .cpuprofile artifact and
// print a per-size timing summary plus the top self-time functions parsed from
// the profile. Optionally time the deployed GET /compute for comparison.
//
// Usage:
//   node tests/profile-compute.js [--sizes 64,128,256,512] [--url <base-url>]
// Env:
//   RESULTS_DIR  if set, the .cpuprofile and JSON report are written there
//   TARGET       optional label recorded in the report
//
// Node 20 built-ins only. The compute module is required from the app directly.

const inspector = require('node:inspector');
const fs = require('node:fs');
const path = require('node:path');
const { performance } = require('node:perf_hooks');

const compute = require('../app/compute');
const {
  request,
  round,
  parseArgs,
  resolveResultsDir,
  writeReport,
} = require('./lib/util');

const DEFAULT_SIZES = [64, 128, 256, 512];

/** Start a CPU profiler session and return start/stop helpers. */
function startProfiler() {
  const session = new inspector.Session();
  session.connect();
  const call = (method, params) =>
    new Promise((resolve, reject) => {
      session.post(method, params || {}, (err, res) => {
        if (err) {
          reject(err);
        } else {
          resolve(res);
        }
      });
    });

  return {
    async start() {
      await call('Profiler.enable');
      await call('Profiler.setSamplingInterval', { interval: 100 });
      await call('Profiler.start');
    },
    async stop() {
      const { profile } = await call('Profiler.stop');
      await call('Profiler.disable');
      session.disconnect();
      return profile;
    },
  };
}

/**
 * Aggregate self-time per function from a V8 CPU profile and return the
 * top entries. Self time per node = sampleInterval * hitCount.
 * @param {object} profile
 * @param {number} topN
 */
function topSelfFunctions(profile, topN = 10) {
  const totalMicros =
    profile.endTime && profile.startTime
      ? profile.endTime - profile.startTime
      : 0;
  const interval = profile.samples && profile.samples.length && totalMicros
    ? totalMicros / profile.samples.length
    : 100; // microseconds fallback

  const byFn = new Map();
  for (const node of profile.nodes) {
    const hit = node.hitCount || 0;
    if (!hit) {
      continue;
    }
    const cf = node.callFrame || {};
    const name = cf.functionName || '(anonymous)';
    const url = cf.url || '';
    const key = `${name} @ ${shortUrl(url)}:${(cf.lineNumber || 0) + 1}`;
    const prev = byFn.get(key) || { selfMs: 0, hitCount: 0 };
    prev.selfMs += (hit * interval) / 1000;
    prev.hitCount += hit;
    byFn.set(key, prev);
  }

  return [...byFn.entries()]
    .map(([fn, v]) => ({ fn, selfMs: round(v.selfMs, 2), hitCount: v.hitCount }))
    .sort((a, b) => b.selfMs - a.selfMs)
    .slice(0, topN);
}

function shortUrl(url) {
  if (!url) {
    return '(native)';
  }
  return url.replace(/^file:\/\//, '').split('/').slice(-2).join('/');
}

async function main() {
  const { flags } = parseArgs(process.argv.slice(2));
  const sizes = (flags.sizes ? String(flags.sizes).split(',') : DEFAULT_SIZES)
    .map((s) => parseInt(s, 10))
    .filter((n) => Number.isFinite(n) && n > 0);
  const url = flags.url || process.env.BASE_URL || null;
  const target = process.env.TARGET || flags.target || 'local';

  console.log(`profile-compute: sizes=[${sizes.join(', ')}]  profiler=node:inspector`);

  const profiler = startProfiler();
  await profiler.start();

  const localTimings = [];
  for (const n of sizes) {
    // Warm once (JIT) then measure.
    compute.multiply(Math.min(n, 64));
    const start = performance.now();
    const res = compute.multiply(n);
    const elapsedMs = performance.now() - start;
    localTimings.push({
      n,
      durationMs: round(res.durationMs, 3),
      wallMs: round(elapsedMs, 3),
      checksum: round(res.checksum, 4),
    });
    console.log(`  local  n=${String(n).padStart(4)}  durationMs=${round(res.durationMs, 2)}`);
  }

  const profile = await profiler.stop();
  const top = topSelfFunctions(profile, 10);

  // Optionally time the deployed endpoint for comparison.
  let deployedTimings = null;
  if (url) {
    deployedTimings = [];
    console.log(`\nprofile-compute: timing deployed GET ${url}/compute`);
    for (const n of sizes) {
      try {
        const res = await request(url, { path: `/compute?n=${n}`, timeoutMs: 60000 });
        const data = res.statusCode === 200 ? JSON.parse(res.body) : {};
        deployedTimings.push({
          n,
          httpTotalMs: round(res.totalMs, 2),
          serverDurationMs: data.durationMs != null ? round(data.durationMs, 3) : null,
          statusCode: res.statusCode,
        });
        console.log(
          `  deployed n=${String(n).padStart(4)}  http=${round(res.totalMs, 2)}ms  server=${data.durationMs != null ? round(data.durationMs, 2) : 'n/a'}ms`
        );
      } catch (err) {
        deployedTimings.push({ n, error: String(err && err.code ? err.code : err.message) });
        console.log(`  deployed n=${n}  error=${err.message}`);
      }
    }
  }

  // Write the .cpuprofile artifact.
  const resultsDir = resolveResultsDir(flags);
  const outDir = resultsDir || process.cwd();
  const profilePath = path.join(outDir, `compute-${Date.now()}.cpuprofile`);
  fs.writeFileSync(profilePath, JSON.stringify(profile));

  const report = {
    test: 'profile-compute',
    target,
    sizes,
    local: localTimings,
    deployed: deployedTimings,
    topSelfFunctions: top,
    cpuprofile: profilePath,
  };

  printSummary(localTimings, top, profilePath);

  const written = writeReport(resultsDir, 'profile-compute', report);
  if (written) {
    console.log(`report written: ${written}`);
  }
}

function printSummary(localTimings, top, profilePath) {
  console.log('\n=== profile-compute summary ===');
  console.log('time per size (in-process):');
  for (const t of localTimings) {
    console.log(`  n=${String(t.n).padStart(4)}  durationMs=${t.durationMs}`);
  }
  console.log('\ntop self-time functions:');
  for (const f of top) {
    console.log(`  ${String(f.selfMs).padStart(8)} ms  (${f.hitCount} samples)  ${f.fn}`);
  }
  console.log(`\ncpuprofile: ${profilePath}`);
  console.log('(open in Chrome DevTools -> Performance -> Load profile)');
}

main().catch((err) => {
  console.error('profile-compute failed:', err);
  process.exit(1);
});
