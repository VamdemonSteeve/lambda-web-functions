# lambda-web-functions

One Express.js app, run on **three AWS compute platforms** and benchmarked head
to head under an equalized setup (same Node 24 / Arm64 runtime, same API Gateway
front door):

1. **Lambda Event Function** (`lambda`) — classic AWS Lambda running the server
   via the Lambda Web Adapter, behind a Function URL.
2. **Lambda Web Function** (`webfn`) — the native AWS Lambda Web Function: a
   port-listening HTTP server with no adapter and no handler, packaged as a ZIP
   on S3 and served from a HomeRegion endpoint.
3. **ECS Fargate** (`fargate`) — the same container image behind an Application
   Load Balancer.

The app (`app/`) is a small Express server that does CPU work (matrix
multiplication), touches the local filesystem, reports process info (including a
cold-start flag), and streams a chunked response — so cold start, throughput,
filesystem speed, compute, and streaming can be compared across platforms.

## Findings

**See [`COMPARISON.md`](COMPARISON.md)** for the full writeup: the equalized
three-way performance comparison, the scaling models, a cost section with the
three billing models and break-even points vs. a 24×7 Fargate task, and a
when-to-use-which decision guide.

Short version: once runtime, CPU architecture, and ingress are equalized, raw
performance is within noise across all three — so the choice is driven by the
**operational and cost model**, not speed. Event Function for simple spiky
request/response, Web Function for streaming or wait-heavy servers at moderate
scale, Fargate for always-on, sustained, or full-control workloads.

## Prerequisites

- **Docker / buildx** — to build and push the shared container image
  (`linux/arm64`) used by the `lambda` and `fargate` targets.
- **AWS CLI v2** (with the `lambda-web` commands) — authenticated with
  credentials that can manage ECR, Lambda, IAM, ECS, EC2 (networking), ELB, S3,
  and API Gateway.
- **Node.js 20+** and **jq** — to run the app, the packaging step, and the test
  harness. The tests use only Node built-ins; the app's only runtime dependency
  is `express`.

All names and sizing (region, memory, CPU, repo/function/cluster names, app env
vars) live in [`scripts/common.sh`](scripts/common.sh) and are overridable from
the environment.

## Run order

```bash
export AWS_REGION=us-east-1

# 1. Build + push the shared Node 24 / Arm64 image (lambda + fargate).
bash scripts/build-and-push.sh

# 2. Deploy the targets.
bash scripts/deploy-lambda.sh                 # Lambda Event Function (prints Function URL)
WEBFN_S3_BUCKET=<bucket> bash scripts/deploy-webfn.sh   # native Web Function (zip -> S3)
bash scripts/deploy-fargate.sh                # ECS Fargate behind an ALB

# 3. Front all three with one API Gateway (prints /lambda, /webfn, /ecs base URLs).
bash scripts/deploy-apigw.sh

# 4. Run the test harness against each target via the gateway.
GW=https://<api-id>.execute-api.us-east-1.amazonaws.com
bash scripts/run-tests.sh lambda  "$GW/lambda"
bash scripts/run-tests.sh webfn   "$GW/webfn"
bash scripts/run-tests.sh fargate "$GW/ecs"

# 5. Tear everything down (stops billing).
WEBFN_S3_BUCKET=<bucket> bash scripts/teardown.sh all --delete-ecr
```

Reports land in `tests/results/<target>-<timestamp>/` (git-ignored), one JSON
report and one captured log per test, so runs can be diffed directly.

## The five tests

| Test | File | What it measures |
|------|------|------------------|
| Load / throttling | `tests/load-test.js` | N requests at `/compute` with bounded concurrency; latency p50/p90/p99, success / 429 / reset counts, throughput, wall time. For `webfn` it also breaks down the `lambda-web-error-type` throttle reasons. |
| Filesystem speed | `tests/fs-bench.js` | `/store` at increasing payload sizes; write/read ms and MB/s per size. |
| Compute profiling | `tests/profile-compute.js` | `app/compute.multiply` under the Node CPU profiler across matrix sizes; writes a `.cpuprofile` and per-size timing. |
| Cold start | `tests/cold-start.js` | first vs steady-state latency and cold-start frequency (per platform's mechanism). |
| TTFB / streaming | `tests/stream-ttfb.js` | `/stream` TTFB vs total transfer time; flags streaming vs buffered. |

## Running locally

```bash
cd app && npm install && cd ..
PORT=8080 STORAGE_DIR=/tmp node app/server.js &
bash scripts/run-tests.sh fargate http://localhost:8080
```

A single local process is always warm, so the cold-start test reports that
honestly rather than inventing cold starts.
