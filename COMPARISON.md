# Lambda Event Function vs Lambda Web Function vs ECS Fargate — consolidated findings

A single standalone summary of the whole comparison: the same Express.js app run
on three AWS compute platforms, measured under an equalized setup, with
performance, scaling, and cost collated in one place. Detailed per-area writeups
live in [`FINDINGS.md`](FINDINGS.md) (lambda vs fargate deep-dive) and
[`FINDINGS-webfn.md`](FINDINGS-webfn.md) (native Web Function); this file is the
decision-oriented roll-up.

- **Account / region:** <ACCOUNT_ID> / us-east-1 (profile `default`)
- **Equalized run:** 2026-11-02, all three back-to-back through one API Gateway
- **Raw results:** `tests/results/{lambda,webfn,fargate}-20261102-*`

---

## 1. The three targets

| | `lambda` | `webfn` | `fargate` |
|---|----------|---------|-----------|
| Platform | AWS Lambda **Event Function** | AWS Lambda **Web Function** (native) | ECS **Fargate** |
| How HTTP works | Express + **Lambda Web Adapter**, Function URL | port-listening server, **no adapter**, HomeRegion endpoint | Express behind an **ALB** |
| Packaging | container image (ECR) | **ZIP → S3** (`S3Object`; no container option) | container image (ECR) |
| Runtime / arch | Node 24 / Arm64 | Node 24 / Arm64 | Node 24 / Arm64 |
| Sizing (measured) | 2048 MB (CPU scales w/ memory) | fixed 2 vCPU / 2 GB | 1 vCPU / 2048 MB |

All three run the **same application source**. `lambda` and `fargate` share the
exact same container image; `webfn` runs the same code packaged as a zip (Web
Functions cannot deploy from a container image).

---

## 2. What was equalized (so the comparison is fair)

Three confounds from earlier runs were removed:

1. **Ingress** — all three hit through the *same* API Gateway HTTP API
   (`/lambda`, `/webfn`, `/ecs` path prefixes → the respective backends).
2. **Runtime + CPU architecture** — the shared image was rebuilt on
   `node:24-slim` / `linux/arm64`; lambda (`--architectures arm64`) and fargate
   (`cpuArchitecture=ARM64`) redeployed. webfn was already Node 24 / Arm64. All
   three `/info` endpoints confirmed **Node v24.x on linux**.
3. **Wall-clock** — re-run back-to-back in one session, not stitched across days.

Only the **platform primitive** and **packaging** differ now — the two things
that are inherent to what's being compared and cannot be equalized without
changing what each target *is*.

---

## 3. Performance (equalized, all via the gateway)

Load = 1000 requests @ concurrency 50 to `/compute?n=64`.

| Metric | `lambda` | `fargate` | `webfn` | Reading |
|--------|----------|-----------|---------|---------|
| **Compute n=512 (ms, server)** | 82.3 | 83.2 | 84.6 | **flat tie** (~3%), identical checksum |
| **Load p50 (ms)** | 153.8 | 143.0 | 145.3 | tight band (~8%) |
| **Load p99 (ms)** | 1085.9 | 577.0 | 612.9 | lambda tail widest (cold inits in burst) |
| **Throughput (req/s)** | 248.0 | 294.9 | 285.3 | fargate/webfn edge out lambda |
| **Load success / 1000** | 1000 | 1000 | 1000 | no throttling anywhere |
| **FS 8MB write / read (MB/s)** | 861 / 1213 | 1474 / 2453 | 1976 / 2238 | webfn fastest writer |
| **TTFB / total p50 (ms), via GW** | 1251 / 1251 | 1238 / 1238 | 1257 / 1257 | all **buffered** (ratio 1.0) |
| **Streaming, direct (no GW)** | buffered* | n/a | **134 / 1236 → streaming** | webfn's structural edge |

\* lambda has a RESPONSE_STREAM Function URL, but behind the API Gateway it
buffers like the rest.

**Takeaways:**
- **Once Node/arch match, raw compute and request latency are within noise
  across all three.** The earlier "webfn ~2.7× slower on compute" was entirely
  the Arm64/Node-24-vs-amd64/Node-20 difference — not the platform.
- **Streaming is the one structural performance difference.** Native Web
  Functions stream (first byte long before completion) when hit directly; a
  buffering API Gateway erases that advantage for everyone, so it only matters
  if you don't put a buffering front door in front.

> ⚠️ Single-run numbers. The load **p99** spread is run-to-run variance
> (lambda's wider tail = ~10% cold-starts in that burst), not a fixed ranking.
> Compute, filesystem, and streaming-mode are structural and robust. For a
> defensible load ranking, average 3–5 runs per target.

---

## 4. Scaling

| | `lambda` (Event Fn) | `webfn` (Web Fn) | `fargate` |
|---|---------------------|------------------|-----------|
| Unit of scale | 1 execution env **per concurrent invocation** | 1 warm env serves **many** concurrent requests (up to `maxConcurrencyPerEnvironment`, default 64) | fixed task count unless autoscaling attached |
| Observed under 1000 @ 50 | fans out to ~49 envs | absorbed in a handful of warm envs (peak per-env concurrency **2**, max mem ~222 MB) | all funneled through 1 task (or scales 1→N on CPU alarm, minutes-scale) |
| Scale to zero | yes | **yes** | no (min 1 task always running) |
| Reaction time | seconds, per request | seconds, per request; warm envs cut cold starts "by orders of magnitude" | minutes (CloudWatch alarm + task launch) |
| Throttle signal | 429 `TooManyRequestsException` | 429 + `lambda-web-error-type` header; 503 `Platform.EndpointDisabled` when `rateLimit=0` | none (requests queue at the task) |

Measured for webfn from the `AWS/Lambda/Web` CloudWatch namespace. None of the
three throttled at 1000/50.

---

## 5. Cost

### 5.1 The three billing models

| | Billing basis | Pays for idle wait? | Idle / scale-to-zero cost |
|---|---------------|---------------------|---------------------------|
| **Event Function** | per request + **GB-second of wall duration** | **yes** — full duration billed, incl. time blocked on I/O | $0 when idle |
| **Web Function** | per request + **active vCPU-second** + GB-second of memory *while the env exists* | **mostly no** — idle CPU ≈ free; memory still billed while env is warm | approaches $0 as it scales to zero |
| **Fargate** | **per running-task vCPU-second + GB-second**, continuously | **yes** — billed whether busy or idle | **no** — min 1 task bills 24/7 |

### 5.2 Published rates (US-East, Arm/Graviton)

Per the [AWS Lambda pricing page](https://aws.amazon.com/lambda/pricing/) and
[AWS Fargate pricing](https://aws.amazon.com/fargate/pricing/); exact Lambda Web
Function figures corroborated across the
[AWS builder blog](https://builder.aws.com/content/3KVvIb9GOBUUwLwDHQiiLSgkPZo/you-dont-pay-for-the-wait-lambda-web-functions-for-ai)
and [logeshwaran.org](https://www.logeshwaran.org/2026/10/lambda-web-functions-deploy-express.html).
Content rephrased for licensing compliance.

| Dimension | Event Function (Arm) | Web Function (Arm) | Fargate (Arm) |
|-----------|----------------------|--------------------|---------------|
| Requests | $0.20 / million | $0.30 / million | — |
| Compute | $0.0000133334 / GB-sec (wall duration) | **$0.0000276944 / active vCPU-sec** | $0.038 / vCPU-hour |
| Memory | (included in GB-sec) | **$0.0000036667 / GB-sec** (while env lives) | $0.004445 / GB-hour |
| Free tier | 1M req + 400k GB-sec/mo | check current page | none |

> ⚠️ **Verify before relying on these.** The AWS pricing pages are JS-rendered
> and were not machine-read here; the Lambda rates come from third-party
> summaries current around the Oct 2026 launch. Confirm against the live pricing
> page for your region before using them in a real estimate. Fargate per-hour
> rates are the long-standing Graviton rates; confirm similarly.

### 5.3 What our metrics showed — "you don't pay for the wait"

Over the webfn test window, CloudWatch reported:

| | Value |
|---|-------|
| `EnvironmentCPUTime` (active CPU) | ~20,230 vCPU-seconds |
| `EnvironmentActiveTime` (env wall time, summed across envs) | ~6,329,467 env-seconds |
| Ratio (wall : active CPU) | **~313 : 1** |

Environments existed ~313× longer than they used CPU. On the Web Function model
that idle time costs only the (cheaper) memory component, not the vCPU
component. An **Event Function** doing the same I/O-bound work would bill the
full wall duration; **Fargate** bills its task continuously regardless.

### 5.4 Illustrative monthly cost (same workload, three platforms)

Assumptions (round numbers for shape, not a quote): **10 M requests/month**,
each **50 ms wall** of which **~5 ms is active CPU** (I/O-bound, e.g. awaiting a
DB/model), **2 GB** memory footprint, and for Fargate a steady **1 task
(1 vCPU / 2 GB) running 24×7**.

| Platform | Requests | Compute | Memory | **≈ Monthly** | Note |
|----------|----------|---------|--------|---------------|------|
| **Event Function** | $2.00 | 10M × 0.05s × 2GB × $0.0000133334 ≈ **$13.3** | (in compute) | **≈ $15** | pays for the full 50 ms wall |
| **Web Function** | $3.00 | 10M × 0.005s(1 vCPU) × $0.0000276944 ≈ **$1.4** | ~2GB while warm; scales to zero when idle ≈ **$5–15** | **≈ $10–20** | active-CPU only; memory depends on warm-env hours |
| **Fargate** | — | 1 vCPU × 730h × $0.038 ≈ **$27.7** | 2GB × 730h × $0.004445 ≈ **$6.5** | **≈ $34** | billed 24×7 regardless of traffic |

**Read:** for **spiky or I/O-bound** traffic, the active-CPU model (Web
Function) and the pay-per-use model (Event Function) are far cheaper than a
24×7 Fargate task, because Fargate pays for idle time and the others don't. The
Web Function's edge over the Event Function grows as the **wait-to-CPU ratio
grows** (our measured 313:1 is extreme but points the right way): the more your
request time is spent waiting on a DB/API/model, the more "you don't pay for the
wait" saves. For **sustained, CPU-bound, high-utilization** traffic the gap
narrows and a continuously-running Fargate task (or Lambda provisioned capacity)
can win on predictability.

> ⚠️ The $ figures above are **illustrative arithmetic on assumed usage**, not a
> measured bill. Real cost depends on your request rate, per-request active CPU,
> how long Web Function environments stay warm between bursts, and Fargate task
> count. Treat the **ordering and the drivers** as the finding, not the
> absolute dollars.

---

## 5.5 Break-even vs ECS Fargate

Fargate is a **flat** cost — a 24×7 task bills the same whether it serves 1 or
100 M requests. Both Lambda options are **usage-proportional** — ~$0 at idle,
rising with traffic. So each has a crossover request volume where its bill equals
Fargate's: **below it the Lambda option is cheaper; above it Fargate is cheaper.**

**Baseline Fargate cost** (the deployed sizing, 1 vCPU / 2 GB, Arm, 24×7):
1 vCPU × 730 h × $0.038 + 2 GB × 730 h × $0.004445 ≈ **$34.23 / month**. That is
the flat number both Lambda options are racing against.

The crossover depends heavily on **how much active CPU each request burns**,
because that is exactly what the Web Function bills for and the Event Function
does not. Break-even monthly request volume (and the equivalent sustained
req/s), for the four profiles from §5.4:

| Per-request profile | Event Function cost/M | **EF break-even** | Web Function cost/M | **WF break-even** |
|---------------------|-----------------------|-------------------|---------------------|-------------------|
| I/O-bound (50 ms wall, 5 ms CPU)  | $1.53 | **~22 M req/mo (~8 req/s)**  | $0.81 | **~43 M req/mo (~16 req/s)** |
| Balanced (50 ms wall, 25 ms CPU)  | $1.53 | ~22 M req/mo (~8 req/s)  | $1.36 | ~25 M req/mo (~10 req/s) |
| CPU-bound (50 ms wall, 50 ms CPU) | $1.53 | ~22 M req/mo (~8 req/s)  | $2.05 | ~17 M req/mo (~6 req/s) |
| Heavy (200 ms wall, 150 ms CPU)   | $5.53 | ~6 M req/mo (~2 req/s)   | $5.92 | ~6 M req/mo (~2 req/s) |

**How to read it:**
- **The crossover is a volume, not a date.** If your steady traffic is *below*
  the break-even req/s for a given option, that Lambda option is cheaper than a
  24×7 Fargate task; above it, the always-on task wins.
- **Event Function break-even is flat (~22 M req/mo) across the first three
  profiles** because it bills *wall* duration (50 ms), independent of how much of
  that is CPU. It only drops (to ~6 M) when wall time itself grows (the heavy
  profile).
- **Web Function break-even swings with CPU intensity** — exactly the model's
  signature. For I/O-bound work it tolerates **~2× the volume** of the Event
  Function before matching Fargate (~43 M vs ~22 M req/mo), because idle wait is
  nearly free. As requests become CPU-bound, its break-even falls *below* the
  Event Function's (~17 M), since active-CPU billing now dominates.
- **Rule of thumb:** for **bursty or I/O-bound** APIs under roughly **10–40 M
  req/month (~5–15 req/s sustained)**, a Lambda option is cheaper than a 24×7
  Fargate task — and the Web Function stretches that ceiling highest when
  requests spend most of their time waiting. For **sustained high volume** above
  the crossover, or for always-busy CPU-bound load, the flat Fargate task is
  cheaper (and a second always-on task just raises the bar it must beat).

> ⚠️ **Model, not a quote.** Same caveats as §5.2/§5.4: rates are
> verify-before-use; the Web Function memory term is modeled as proportional to
> busy time (a lower bound — a long-warm idle env bills more memory and lowers
> its break-even), and Fargate's number assumes a single always-on task with no
> autoscaling. A second Fargate task doubles the flat cost and roughly doubles
> every break-even volume. Compute the crossover with your real per-request
> active-CPU and warm-env hours before committing.

---

## 6. Decision guide

| If you need… | Best fit | Why |
|--------------|----------|-----|
| **Real HTTP streaming** (SSR, token-by-token AI) | **Web Function** (direct, no buffering gateway) | only target that streamed first-byte-early; the others buffer |
| **Lowest cost for spiky / I/O-bound** traffic | **Web Function** or **Event Function** | scale to zero; active-CPU (webfn) makes idle wait ≈ free |
| **Many concurrent requests per env** / shared warm state | **Web Function** | one warm env serves up to 64 concurrent requests |
| **A standard port-listening server, no handler/adapter** | **Web Function** | native HTTP; no code gymnastics |
| **Mature ecosystem, sidecars, long-running/background work, full control** | **Fargate** | always-on container, any port, any process model |
| **Simple request/response, existing Lambda tooling, per-request isolation** | **Event Function** | one invocation per env, well-trodden path |
| **Predictable sustained high-CPU load** | **Fargate** (or Lambda provisioned) | flat per-hour cost; no per-request scaling overhead |

**Bottom line:** with runtime, architecture, and ingress equalized, **raw
performance no longer separates these platforms** — compute and latency are
within noise. Choose on the **operational and cost model**: native streaming and
active-CPU billing (Web Function), scale-to-zero pay-per-use (Event Function), or
always-on full-control containers (Fargate).

---

## 7. Conclusion — when to use which

Because performance is effectively a tie once the runtime and ingress match, the
choice comes down to traffic shape, workload character, and operational needs.
Reach for a **Lambda Event Function** when you have classic, bursty
request/response or event-driven work at low-to-moderate volume (below roughly
8 req/s sustained against a single Fargate task) and you want the simplest,
best-trodden pay-per-use path with per-request isolation and scale-to-zero. Pick
a **Lambda Web Function** when you want to run a normal port-listening HTTP
server with no handler or adapter, need genuine response streaming (SSR,
token-by-token AI — provided you don't hide it behind a buffering API Gateway),
or run I/O-bound workloads that spend most of their time waiting on a database,
API, or model: its active-CPU billing makes that idle wait nearly free and
pushes the cost crossover vs. Fargate the highest (~16 req/s for I/O-bound
traffic), while one warm environment absorbing many concurrent requests keeps
cold starts rare. Choose **ECS Fargate** when you need a full long-running
container — sidecars, background processes, non-HTTP ports, large images, or
sustained high-CPU/high-volume traffic above the break-even — where a flat,
predictable 24×7 bill beats per-request pricing and you want maximum control over
the runtime. In short: **Event Function for simple spiky request/response, Web
Function for streaming or wait-heavy servers at moderate scale, Fargate for
always-on, sustained, or full-control workloads** — and above the crossover
volumes in §5.5, the always-on container wins on cost.

---

## 8. Reproducing

```bash
export AWS_PROFILE=default AWS_REGION=us-east-1
# shared Node 24 / Arm64 image for lambda + fargate
bash scripts/build-and-push.sh
bash scripts/deploy-lambda.sh
bash scripts/deploy-fargate.sh
# native Web Function (zip → S3)
WEBFN_S3_BUCKET=lwf-webfn-<ACCOUNT_ID>-us-east-1 bash scripts/deploy-webfn.sh
# one front door for all three
bash scripts/deploy-apigw.sh
# run the suite against each via the gateway
GW=https://<api-id>.execute-api.us-east-1.amazonaws.com
bash scripts/run-tests.sh lambda  "$GW/lambda"
bash scripts/run-tests.sh webfn   "$GW/webfn"
bash scripts/run-tests.sh fargate "$GW/ecs"
```

Teardown (stops all billing):

```bash
WEBFN_S3_BUCKET=lwf-webfn-<ACCOUNT_ID>-us-east-1 bash scripts/teardown.sh all --delete-ecr
```
