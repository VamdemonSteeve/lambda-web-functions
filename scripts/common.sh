#!/usr/bin/env bash
# Shared configuration for the lambda-web-functions deploy/teardown scripts.
#
# This file is SOURCED by the other scripts, so it deliberately does NOT set
# `set -euo pipefail` (that would leak into and abort the sourcing script).
# Every value is overridable from the environment via `: "${VAR:=default}"`.
#
# Sizing (Lambda memory, Fargate cpu/memory) and the app env vars
# (PORT/MATRIX_SIZE/STORAGE_DIR) live here so both deploy scripts stay matched.

# --- AWS account / region -------------------------------------------------
: "${AWS_REGION:=us-east-1}"

# Resolve the account id lazily and guard it: a missing/expired credential must
# NOT abort a script that merely sources this file (e.g. teardown dry inspection
# or `source common.sh` in verification). 2>/dev/null + ||true keeps it empty.
if [ -z "${AWS_ACCOUNT_ID:-}" ]; then
  AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
fi
export AWS_ACCOUNT_ID

# --- Container image (ECR) -------------------------------------------------
: "${ECR_REPO:=lambda-web-functions}"
: "${IMAGE_TAG:=latest}"
: "${IMAGE_URI:=${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:${IMAGE_TAG}}"

# --- Lambda ----------------------------------------------------------------
: "${LAMBDA_FUNCTION_NAME:=lwf-lambda}"
: "${LAMBDA_ROLE_NAME:=lwf-lambda-role}"
: "${LAMBDA_MEMORY_MB:=2048}"
: "${LAMBDA_EPHEMERAL_MB:=2048}"

# --- Fargate / ECS ---------------------------------------------------------
: "${FARGATE_CLUSTER:=lwf-cluster}"
: "${FARGATE_SERVICE:=lwf-service}"
: "${FARGATE_TASKDEF:=lwf-task}"
: "${FARGATE_CPU:=1024}"
: "${FARGATE_MEMORY:=2048}"
: "${FARGATE_SG_NAME:=lwf-fargate-sg}"
: "${ALB_NAME:=lwf-alb}"
: "${TG_NAME:=lwf-tg}"

# --- API Gateway (HTTP API / apigatewayv2) ---------------------------------
# Single public front door routing by path prefix to the Lambda (/lambda) and
# the Fargate ALB (/ecs). The ALB DNS + listener ARN are discovered at deploy
# time (by ALB_NAME / listener port 80) rather than hardcoded.
: "${APIGW_NAME:=lwf-http-api}"
# Use the auto-deploy '$default' stage so the invoke URL carries no stage suffix.
: "${APIGW_STAGE:=\$default}"

# --- App runtime (identical across both platforms) -------------------------
: "${CONTAINER_PORT:=8080}"
: "${MATRIX_SIZE:=256}"
: "${STORAGE_DIR:=/tmp}"

# PORT the app listens on inside the container; the Lambda Web Adapter and the
# Fargate container both use this. Kept in sync with CONTAINER_PORT.
: "${PORT:=${CONTAINER_PORT}}"

# --- Lambda Web Function (webfn) -------------------------------------------
# The native Lambda Web Function target (NOT the classic adapter-based lambda
# target above). Packaged as a ZIP uploaded to S3 — Web Functions cannot deploy
# from a container image — and served from a HomeRegion endpoint with no Lambda
# Web Adapter and no handler. 2 GB memory / 2 vCPU are platform-fixed for Web
# Functions, so there is deliberately NO WEBFN_MEMORY_MB knob. The app env vars
# (PORT / MATRIX_SIZE / STORAGE_DIR) are reused from the shared "App runtime"
# block above — the same source runs here, just packaged differently.
: "${WEBFN_FUNCTION_NAME:=lwf-webfn}"
# Dedicated execution role, kept separate from LAMBDA_ROLE_NAME so teardown of
# one target never removes the other's role.
: "${WEBFN_ROLE_NAME:=lwf-webfn-role}"
: "${WEBFN_ENDPOINT_TYPE:=HomeRegion}"
# Verified against a live deploy (2026-10-31): the runtime reported as
# "nodejs24.x:nodejs.web24.v31" and /info showed Node v24.22.1.
: "${WEBFN_RUNTIME:=nodejs24.x}"
# WEBFN_ARCH documents the Web Function's CPU architecture (Arm64). Verified
# against a live deploy: the lambda-web API has NO architecture field at all
# (Web Functions are Arm64-only and the arch is implicit), so WEBFN_ARCH is
# documentation only and is never passed to the CLI. Do NOT add a BUILD_PLATFORM
# knob (there is no webfn container image).
: "${WEBFN_ARCH:=arm64}"
# Entry file for the Node runtime. Native Web Functions expect index.js at the
# zip root unless AWS_LAMBDA_NODEJS_ENTRYPOINT names the real entry file. Our app
# entry is server.js, so this is passed in the revision env. Verified required
# against a live deploy (missing => Runtime.ImportCodeError, 502).
: "${WEBFN_NODEJS_ENTRYPOINT:=server.js}"
# S3 location of the deploy ZIP. The bucket is REQUIRED at deploy time (empty by
# default so an unset bucket is detectable and the deploy script can refuse).
: "${WEBFN_S3_BUCKET:=}"
# Artifact tag is independent of IMAGE_TAG on purpose: IMAGE_TAG is an ECR-image
# concept, and reusing it would couple the zip key to the image and overwrite
# the zip on a same-tag redeploy. Override WEBFN_ARTIFACT_TAG to version zips.
: "${WEBFN_ARTIFACT_TAG:=latest}"
: "${WEBFN_S3_KEY:=webfn/app-${WEBFN_ARTIFACT_TAG:-latest}.zip}"
# Per-request timeout in seconds.
# TODO(webfn): confirm the valid request-timeout range (believed 3-900s).
: "${WEBFN_REQUEST_TIMEOUT:=30}"
# How many concurrent requests one execution environment serves.
# TODO(webfn): confirm the valid maxConcurrencyPerEnvironment range (believed 1-128).
: "${WEBFN_MAX_CONCURRENCY_PER_ENV:=64}"
# Optional caps. Empty => omit the flag entirely (let the service default apply).
: "${WEBFN_MAX_ENVIRONMENTS:=}"
# Optional request rate limit. Empty => omit the flag. NOTE: 0 is a REAL value
# that disables the endpoint, so unset ("") and 0 must stay distinguishable.
# TODO(webfn): confirm the valid rateLimit set (believed {0, 100-1000 step 100,
# 2000-10000 step 1000}).
: "${WEBFN_RATE_LIMIT:=}"

# --- Small shared helper ---------------------------------------------------
# Print a timestamped action line so a human sees each create/update/delete.
log() {
  echo ">> $*"
}
