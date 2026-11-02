#!/usr/bin/env bash
#
# Run the full test harness against a deployed (or local) target and collect
# every report into a single timestamped results directory.
#
# Usage:
#   scripts/run-tests.sh <lambda|fargate|webfn> <base-url>
#
# Each test writes a JSON report into RESULTS_DIR and its stdout is also
# captured to a .log file in the same directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

TARGET="${1:-}"
BASE_URL="${2:-}"

case "$TARGET" in
  lambda|fargate|webfn) ;;
  *)
    echo "usage: $0 <lambda|fargate|webfn> <base-url>" >&2
    exit 2
    ;;
esac
if [ -z "$BASE_URL" ]; then
  echo "usage: $0 <lambda|fargate|webfn> <base-url>" >&2
  exit 2
fi

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TESTS_DIR="${REPO_ROOT}/tests"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_DIR="${TESTS_DIR}/results/${TARGET}-${TIMESTAMP}"
mkdir -p "$RESULTS_DIR"

export RESULTS_DIR
export TARGET
export BASE_URL

log "target:     $TARGET"
log "base url:   $BASE_URL"
log "results in: $RESULTS_DIR"

# webfn-only precheck: a Web Function endpoint can be DISABLED (e.g. rateLimit=0),
# in which case only the load-test contract is meaningful and the other four
# tests need an ENABLED endpoint. Probe /health once via the harness's request()
# (no curl) and WARN — never fatal. TESTS_DIR is a local var here, so pass it
# inline to the node -e so require() resolves regardless of cwd.
# TODO(webfn): confirm the exact "Platform.EndpointDisabled" lambda-web-error-type
# value, and that a disabled endpoint actually rejects /health at the edge.
if [ "$TARGET" = "webfn" ]; then
  log "webfn precheck: probing ${BASE_URL}/health for a disabled endpoint"
  PRECHECK="$(TESTS_DIR="$TESTS_DIR" BASE_URL="$BASE_URL" node -e '
    const { request } = require(process.env.TESTS_DIR + "/lib/util");
    request(process.env.BASE_URL, { path: "/health", method: "GET" })
      .then((r) => {
        const t = (r.headers && r.headers["lambda-web-error-type"]) || "";
        console.log(r.statusCode + " " + t);
      })
      .catch((e) => console.log("ERR " + (e && e.message ? e.message : e)));
  ' 2>&1 || true)"
  log "webfn precheck result: ${PRECHECK}"
  PRECHECK_STATUS="${PRECHECK%% *}"
  PRECHECK_TYPE="${PRECHECK#* }"
  if [ "${PRECHECK_STATUS}" = "503" ]; then
    if [ "${PRECHECK_TYPE}" = "Platform.EndpointDisabled" ]; then
      log "WARN: endpoint is DISABLED (Platform.EndpointDisabled). The load-test"
      log "      still records the throttle/disabled contract, but the other four"
      log "      tests need an ENABLED endpoint to produce meaningful numbers."
    else
      log "WARN: endpoint returned 503; it may be disabled (e.g. rateLimit=0). The"
      log "      load-test still records the contract but the other four tests need"
      log "      an ENABLED endpoint."
    fi
  fi
fi

# Load-test: a local run should use a small count; a deployed run uses 1000.
LOAD_COUNT="${LOAD_COUNT:-1000}"
LOAD_CONCURRENCY="${LOAD_CONCURRENCY:-50}"

run_test() {
  local name="$1"
  shift
  log "running ${name} ..."
  # Capture stdout+stderr to a log; the test also writes its own JSON report.
  if node "$@" >"${RESULTS_DIR}/${name}.log" 2>&1; then
    log "  ${name} ok"
  else
    log "  ${name} FAILED (see ${RESULTS_DIR}/${name}.log)"
  fi
}

run_test "load-test" "${TESTS_DIR}/load-test.js" "$BASE_URL" --count "$LOAD_COUNT" --concurrency "$LOAD_CONCURRENCY"
run_test "fs-bench" "${TESTS_DIR}/fs-bench.js" "$BASE_URL"
run_test "profile-compute" "${TESTS_DIR}/profile-compute.js" --url "$BASE_URL"
run_test "cold-start" "${TESTS_DIR}/cold-start.js" "$TARGET" "$BASE_URL"
run_test "stream-ttfb" "${TESTS_DIR}/stream-ttfb.js" "$BASE_URL"

log "done. reports:"
ls -1 "$RESULTS_DIR"
echo "$RESULTS_DIR"
