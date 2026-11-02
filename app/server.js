'use strict';

const express = require('express');
const compute = require('./compute');
const storage = require('./storage');

// Process-level state. Set once at module load so the first request served by
// this process (a Lambda cold start, or a freshly booted Fargate task) sees
// coldStart=true and every subsequent request sees false.
let coldStart = true;
let requestCount = 0;

// Native Lambda Web Functions inject AWS_LAMBDA_HTTP_ENDPOINT (e.g.
// "0.0.0.0:3000") and require the server to listen on exactly that host:port,
// ignoring any PORT we pick. When it is absent (the lambda-via-LWA target,
// Fargate, and local runs) we fall back to PORT (default 8080), so those
// targets are unaffected.
const LWF_ENDPOINT = process.env.AWS_LAMBDA_HTTP_ENDPOINT || '';
const [LWF_HOST, LWF_PORT] = LWF_ENDPOINT.includes(':')
  ? [LWF_ENDPOINT.slice(0, LWF_ENDPOINT.lastIndexOf(':')), LWF_ENDPOINT.slice(LWF_ENDPOINT.lastIndexOf(':') + 1)]
  : ['', ''];
const PORT = parseInt(LWF_PORT || process.env.PORT || '8080', 10);
const HOST = LWF_HOST || undefined; // undefined => Express default (all interfaces)
const MATRIX_SIZE = parseInt(process.env.MATRIX_SIZE || '256', 10);
const STORAGE_DIR = process.env.STORAGE_DIR || '/tmp';
const MAX_MATRIX = 1024;
const DEFAULT_STORE_SIZE = 1024 * 1024; // 1 MB

const app = express();
app.use(express.json());

// Count every request as it arrives.
app.use((req, res, next) => {
  requestCount += 1;
  next();
});

app.get('/health', (req, res) => {
  res.type('text/plain').status(200).send('ok');
});

app.get('/compute', (req, res) => {
  let n = parseInt(req.query.n, 10);
  if (!Number.isFinite(n) || n <= 0) {
    n = MATRIX_SIZE;
  }
  if (n > MAX_MATRIX) {
    n = MAX_MATRIX;
  }
  res.json(compute.multiply(n));
});

app.post('/store', (req, res) => {
  let size = parseInt(req.query.size, 10);
  if ((!Number.isFinite(size) || size <= 0) && req.body && req.body.size != null) {
    size = parseInt(req.body.size, 10);
  }
  if (!Number.isFinite(size) || size <= 0) {
    size = DEFAULT_STORE_SIZE;
  }
  res.json(storage.writeThenRead(size, STORAGE_DIR));
});

app.get('/info', (req, res) => {
  const wasColdStart = coldStart;
  res.json({
    platform: process.platform,
    nodeVersion: process.version,
    memoryLimitMB: Math.round(require('node:os').totalmem() / (1024 * 1024)),
    requestCount,
    coldStart: wasColdStart,
  });
  // Flip only after capturing, so just the first request reports true.
  coldStart = false;
});

app.get('/stream', (req, res) => {
  let chunks = parseInt(req.query.chunks, 10);
  if (!Number.isFinite(chunks) || chunks <= 0) {
    chunks = 10;
  }
  let delay = parseInt(req.query.delay, 10);
  if (!Number.isFinite(delay) || delay < 0) {
    delay = 100;
  }

  res.status(200).type('text/plain');
  res.flushHeaders();
  // First byte goes out immediately so TTFB is measurable independent of delay.
  res.write('start\n');

  let sent = 0;
  const timer = setInterval(() => {
    if (sent >= chunks) {
      clearInterval(timer);
      res.end('done\n');
      return;
    }
    sent += 1;
    res.write(`chunk ${sent}\n`);
  }, delay);

  req.on('close', () => clearInterval(timer));
});

const listenArgs = HOST ? [PORT, HOST] : [PORT];
app.listen(...listenArgs, () => {
  // eslint-disable-next-line no-console
  console.log(
    `lambda-web-functions app listening on ${HOST || '0.0.0.0'}:${PORT} (MATRIX_SIZE=${MATRIX_SIZE}, STORAGE_DIR=${STORAGE_DIR})`
  );
});

module.exports = app;
