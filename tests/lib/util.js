'use strict';

// Shared helpers for the test harness. Node 20 built-ins ONLY (no npm deps).
// CommonJS to match the app.

const http = require('node:http');
const https = require('node:https');
const { URL } = require('node:url');
const fs = require('node:fs');
const path = require('node:path');
const { performance } = require('node:perf_hooks');

/**
 * Parse a base URL and pick the matching transport module.
 * @param {string} base
 * @returns {{ url: URL, transport: typeof http }}
 */
function clientFor(base) {
  const url = new URL(base);
  const transport = url.protocol === 'https:' ? https : http;
  return { url, transport };
}

/**
 * Perform a single request and measure latency, TTFB and total time.
 * Resolves even on HTTP error status (statusCode is reported, not thrown);
 * rejects only on transport-level errors (ECONNRESET, timeouts, DNS, ...).
 *
 * @param {string} base base URL (scheme://host[:port])
 * @param {object} [opts]
 * @param {string} [opts.path] request path (default '/')
 * @param {string} [opts.method] HTTP method (default 'GET')
 * @param {Buffer|string} [opts.body] request body
 * @param {object} [opts.headers] extra headers
 * @param {number} [opts.timeoutMs] socket timeout (default 30000)
 * @param {boolean} [opts.collectBody] keep the response body (default true)
 * @returns {Promise<{ statusCode: number, ttfbMs: number, totalMs: number, bytes: number, body: string, headers: object }>}
 */
function request(base, opts = {}) {
  const { url, transport } = clientFor(base);
  const reqPath = opts.path || '/';
  const method = opts.method || 'GET';
  const timeoutMs = opts.timeoutMs || 30000;
  const collectBody = opts.collectBody !== false;

  return new Promise((resolve, reject) => {
    const start = performance.now();
    let ttfbMs = -1;
    let bytes = 0;
    const chunks = [];

    const req = transport.request(
      {
        protocol: url.protocol,
        hostname: url.hostname,
        port: url.port || (url.protocol === 'https:' ? 443 : 80),
        path: reqPath,
        method,
        headers: opts.headers || {},
      },
      (res) => {
        res.on('data', (chunk) => {
          if (ttfbMs < 0) {
            ttfbMs = performance.now() - start;
          }
          bytes += chunk.length;
          if (collectBody) {
            chunks.push(chunk);
          }
        });
        res.on('end', () => {
          const totalMs = performance.now() - start;
          // If the body was empty, TTFB == total (no data event fired).
          if (ttfbMs < 0) {
            ttfbMs = totalMs;
          }
          resolve({
            statusCode: res.statusCode,
            ttfbMs,
            totalMs,
            bytes,
            body: collectBody ? Buffer.concat(chunks).toString('utf8') : '',
            headers: res.headers,
          });
        });
      }
    );

    req.on('error', (err) => reject(err));
    req.setTimeout(timeoutMs, () => {
      req.destroy(new Error(`request timeout after ${timeoutMs}ms`));
    });

    if (opts.body != null) {
      req.write(opts.body);
    }
    req.end();
  });
}

/**
 * Stream a request and record the time of each received byte boundary.
 * Like request() but reports the raw text and per-chunk arrival times so
 * callers can analyse progressive delivery.
 *
 * @param {string} base
 * @param {object} [opts] same shape as request()
 * @returns {Promise<{ statusCode: number, ttfbMs: number, totalMs: number, bytes: number, body: string, chunkTimes: number[] }>}
 */
function streamRequest(base, opts = {}) {
  const { url, transport } = clientFor(base);
  const reqPath = opts.path || '/';
  const timeoutMs = opts.timeoutMs || 30000;

  return new Promise((resolve, reject) => {
    const start = performance.now();
    let ttfbMs = -1;
    let bytes = 0;
    const chunks = [];
    const chunkTimes = [];

    const req = transport.request(
      {
        protocol: url.protocol,
        hostname: url.hostname,
        port: url.port || (url.protocol === 'https:' ? 443 : 80),
        path: reqPath,
        method: opts.method || 'GET',
        headers: opts.headers || {},
      },
      (res) => {
        res.on('data', (chunk) => {
          const now = performance.now() - start;
          if (ttfbMs < 0) {
            ttfbMs = now;
          }
          chunkTimes.push(now);
          bytes += chunk.length;
          chunks.push(chunk);
        });
        res.on('end', () => {
          const totalMs = performance.now() - start;
          if (ttfbMs < 0) {
            ttfbMs = totalMs;
          }
          resolve({
            statusCode: res.statusCode,
            ttfbMs,
            totalMs,
            bytes,
            body: Buffer.concat(chunks).toString('utf8'),
            chunkTimes,
          });
        });
      }
    );

    req.on('error', (err) => reject(err));
    req.setTimeout(timeoutMs, () => {
      req.destroy(new Error(`request timeout after ${timeoutMs}ms`));
    });
    req.end();
  });
}

/**
 * Compute a percentile (linear interpolation) from an array of numbers.
 * @param {number[]} values
 * @param {number} p percentile in [0,100]
 * @returns {number}
 */
function percentile(values, p) {
  if (!values.length) {
    return 0;
  }
  const sorted = [...values].sort((a, b) => a - b);
  if (sorted.length === 1) {
    return sorted[0];
  }
  const rank = (p / 100) * (sorted.length - 1);
  const lo = Math.floor(rank);
  const hi = Math.ceil(rank);
  if (lo === hi) {
    return sorted[lo];
  }
  const frac = rank - lo;
  return sorted[lo] + (sorted[hi] - sorted[lo]) * frac;
}

/** Arithmetic mean of an array, or 0 when empty. */
function mean(values) {
  if (!values.length) {
    return 0;
  }
  return values.reduce((a, b) => a + b, 0) / values.length;
}

/** Round to a fixed number of decimals and return a Number. */
function round(value, decimals = 2) {
  const f = 10 ** decimals;
  return Math.round(value * f) / f;
}

/**
 * Run tasks with a bounded concurrency pool. `tasks` is an array of
 * zero-arg functions returning promises. Resolves once all complete.
 * Never rejects; individual task rejections are left to the task itself.
 *
 * @param {Array<() => Promise<any>>} tasks
 * @param {number} concurrency
 * @returns {Promise<void>}
 */
async function runPool(tasks, concurrency) {
  const limit = Math.max(1, concurrency);
  let next = 0;
  async function worker() {
    while (true) {
      const index = next;
      next += 1;
      if (index >= tasks.length) {
        return;
      }
      await tasks[index]();
    }
  }
  const workers = [];
  for (let i = 0; i < limit && i < tasks.length; i++) {
    workers.push(worker());
  }
  await Promise.all(workers);
}

/** Sleep for ms milliseconds. */
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Minimal argv parser: returns { _: positional[], flags: { name: value } }.
 * `--count 50` -> flags.count = '50'. `--foo` with no value -> flags.foo = true.
 * @param {string[]} argv typically process.argv.slice(2)
 */
function parseArgs(argv) {
  const positional = [];
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (token.startsWith('--')) {
      const name = token.slice(2);
      const nextToken = argv[i + 1];
      if (nextToken != null && !nextToken.startsWith('--')) {
        flags[name] = nextToken;
        i += 1;
      } else {
        flags[name] = true;
      }
    } else {
      positional.push(token);
    }
  }
  return { _: positional, flags };
}

/**
 * Resolve the output directory for a report: RESULTS_DIR env, then --out flag,
 * else null (callers print to stdout only).
 * @param {object} flags
 * @returns {string|null}
 */
function resolveResultsDir(flags) {
  const dir = process.env.RESULTS_DIR || (flags && flags.out) || null;
  if (dir && typeof dir === 'string') {
    fs.mkdirSync(dir, { recursive: true });
    return dir;
  }
  return null;
}

/**
 * Write a JSON report into resultsDir (if set) under <name>.json.
 * @param {string|null} resultsDir
 * @param {string} name file stem
 * @param {object} data
 * @returns {string|null} the written path or null
 */
function writeReport(resultsDir, name, data) {
  if (!resultsDir) {
    return null;
  }
  const file = path.join(resultsDir, `${name}.json`);
  fs.writeFileSync(file, JSON.stringify(data, null, 2));
  return file;
}

module.exports = {
  request,
  streamRequest,
  percentile,
  mean,
  round,
  runPool,
  sleep,
  parseArgs,
  resolveResultsDir,
  writeReport,
};
