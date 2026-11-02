'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { performance } = require('node:perf_hooks');

/**
 * Write a buffer of sizeBytes to the given storage directory, read it back,
 * and return timing for each operation separately. The temp file is removed
 * before returning. A unique filename is used per call so concurrent calls do
 * not collide.
 *
 * @param {number} sizeBytes payload size in bytes
 * @param {string} [storageDir] writable directory (default STORAGE_DIR or /tmp)
 * @returns {{ path: string, sizeBytes: number, writeMs: number, readMs: number, writeMBps: number, readMBps: number }}
 */
function writeThenRead(sizeBytes, storageDir) {
  const dir = storageDir || process.env.STORAGE_DIR || '/tmp';
  fs.mkdirSync(dir, { recursive: true });

  const filename = `lwf-store-${process.pid}-${Date.now()}-${Math.round(
    performance.now() * 1000
  )}.bin`;
  const filePath = path.join(dir, filename);

  const buffer = Buffer.alloc(sizeBytes, 0x61);

  const writeStart = performance.now();
  fs.writeFileSync(filePath, buffer);
  const writeMs = performance.now() - writeStart;

  const readStart = performance.now();
  const readBack = fs.readFileSync(filePath);
  const readMs = performance.now() - readStart;

  // Touch the length so the read cannot be optimized away.
  const bytesRead = readBack.length;

  try {
    fs.unlinkSync(filePath);
  } catch (err) {
    // Non-fatal: ephemeral storage is wiped between runs anyway.
  }

  const megabytes = bytesRead / (1024 * 1024);
  const writeMBps = writeMs > 0 ? megabytes / (writeMs / 1000) : 0;
  const readMBps = readMs > 0 ? megabytes / (readMs / 1000) : 0;

  return {
    path: filePath,
    sizeBytes: bytesRead,
    writeMs,
    readMs,
    writeMBps,
    readMBps,
  };
}

module.exports = { writeThenRead };
