'use strict';

const { performance } = require('node:perf_hooks');

/**
 * Build a deterministic n x n matrix. The fill is seeded purely from the
 * cell indices (no Math.random) so repeated calls with the same n produce
 * identical matrices and therefore a stable checksum.
 *
 * @param {number} n
 * @returns {number[][]}
 */
function buildMatrix(n) {
  const m = new Array(n);
  for (let i = 0; i < n; i++) {
    const row = new Array(n);
    for (let j = 0; j < n; j++) {
      row[j] = ((i * 31 + j) % 97) / 97;
    }
    m[i] = row;
  }
  return m;
}

/**
 * Multiply two deterministic n x n matrices with a plain triple loop and
 * return timing plus a checksum. The checksum accumulates every result cell
 * so V8 cannot eliminate the multiplication as dead code.
 *
 * @param {number} n matrix dimension
 * @returns {{ n: number, durationMs: number, checksum: number }}
 */
function multiply(n) {
  const a = buildMatrix(n);
  const b = buildMatrix(n);
  const c = new Array(n);
  for (let i = 0; i < n; i++) {
    c[i] = new Array(n).fill(0);
  }

  const start = performance.now();

  let checksum = 0;
  for (let i = 0; i < n; i++) {
    const ai = a[i];
    const ci = c[i];
    for (let k = 0; k < n; k++) {
      const aik = ai[k];
      const bk = b[k];
      for (let j = 0; j < n; j++) {
        ci[j] += aik * bk[j];
      }
    }
    for (let j = 0; j < n; j++) {
      checksum += ci[j];
    }
  }

  const durationMs = performance.now() - start;

  return { n, durationMs, checksum };
}

module.exports = { multiply };
