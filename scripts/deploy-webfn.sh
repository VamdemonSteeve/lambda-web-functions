#!/usr/bin/env bash
#
# Deploy the SAME app source as a native Lambda Web Function (the "webfn"
# target). Unlike the classic lambda target (deploy-lambda.sh), there is NO
# container image and NO Lambda Web Adapter: Web Functions cannot deploy from an
# ECR image, so this script ZIPs app/ (+ node_modules) and uploads it to S3,
# then creates or updates the Web Function and prints the endpoint URL last.
# Idempotent create-or-update throughout. Sizing is platform-fixed (2 GB / 2
# vCPU) so there is no memory knob; config comes from common.sh.
#
# Web Functions live under the SEPARATE `aws lambda-web` service (NOT
# `aws lambda`). A single `create-web-function` call creates the function, its
# initial revision (code = S3Object) and a HomeRegion endpoint together; a
# redeploy of an existing function adds a new revision via
# `create-web-function-revision`, which the LatestRevision endpoint picks up
# automatically. Web Functions are Arm64-only and the architecture is implicit
# (there is no architecture field in the API), so WEBFN_ARCH is documentation
# only and is never passed to the CLI.
#
# Requires: AWS credentials, zip, jq, and a writable S3 bucket (WEBFN_S3_BUCKET).
# Does NOT require Docker and does NOT run build-and-push.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# deploy-lambda/deploy-fargate do not define REPO_ROOT; webfn needs it to reach
# app/ for packaging, so define it here (as build-and-push.sh does).
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

# common.sh has no endpoint-name knob; derive a stable one from the function
# name (overridable from the environment, matching common.sh's convention).
: "${WEBFN_ENDPOINT_NAME:=${WEBFN_FUNCTION_NAME}-endpoint}"

# --- 1. Account guard -------------------------------------------------------
if [ -z "${AWS_ACCOUNT_ID}" ]; then
  echo "ERROR: could not resolve AWS account id (no valid credentials?)." >&2
  exit 1
fi

ROLE_ARN=""

# --- 2. Execution role ------------------------------------------------------
# Dedicated role (WEBFN_ROLE_NAME), separate from the lambda target's role.
log "Ensuring webfn execution role '${WEBFN_ROLE_NAME}' exists"
if aws iam get-role --role-name "${WEBFN_ROLE_NAME}" >/dev/null 2>&1; then
  log "Role '${WEBFN_ROLE_NAME}' already exists, reusing"
else
  log "Creating role '${WEBFN_ROLE_NAME}'"
  # lambda.amazonaws.com is the right trust principal for now; if the Web
  # Functions service principal differs, this trust policy may need adjusting.
  aws iam create-role \
    --role-name "${WEBFN_ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": { "Service": "lambda.amazonaws.com" },
          "Action": "sts:AssumeRole"
        }
      ]
    }' >/dev/null
  log "Attaching AWSLambdaBasicExecutionRole to '${WEBFN_ROLE_NAME}'"
  aws iam attach-role-policy \
    --role-name "${WEBFN_ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  log "Waiting for IAM role to propagate"
  sleep 10
fi
ROLE_ARN="$(aws iam get-role --role-name "${WEBFN_ROLE_NAME}" --query 'Role.Arn' --output text)"

# --- 3. Package app/ as a ZIP and upload to S3 -----------------------------
if [ -z "${WEBFN_S3_BUCKET}" ]; then
  echo "ERROR: WEBFN_S3_BUCKET is not set. A writable S3 bucket is required to" >&2
  echo "       stage the webfn deploy ZIP. Set it, e.g.:" >&2
  echo "         WEBFN_S3_BUCKET=my-bucket ./scripts/deploy-webfn.sh" >&2
  # The bucket must pre-exist and be writable by the caller's credentials; this
  # script does not auto-create it.
  exit 1
fi

S3_URI="s3://${WEBFN_S3_BUCKET}/${WEBFN_S3_KEY}"

log "Installing production dependencies in app/"
# npm ci requires a committed package-lock.json; the repo does not track a
# lockfile, so use npm install --omit=dev here.
( cd "${REPO_ROOT}/app" && npm install --omit=dev )

STAGE_DIR="$(mktemp -d)"
# Clean the staging dir up on any exit so repeated runs do not leak temp files.
trap 'rm -rf "${STAGE_DIR}"' EXIT
STAGE_ZIP="${STAGE_DIR}/webfn-app.zip"

log "Zipping app/ (+ node_modules) into ${STAGE_ZIP}"
( cd "${REPO_ROOT}/app" && zip -qr "${STAGE_ZIP}" . -x '*.git*' )

log "Uploading deploy ZIP to ${S3_URI}"
aws s3 cp "${STAGE_ZIP}" "${S3_URI}" --region "${AWS_REGION}"

# --- 4. Build the shared revision JSON blocks (code + service config) ------
# Code lives in revisionConfig.buildConfig.codeConfig.s3Object (bucket/key);
# versionId is optional and omitted. Runtime is the common.sh WEBFN_RUNTIME
# token ("nodejs24.x"). There is NO architecture field anywhere in the schema
# (Arm64 is implicit), so WEBFN_ARCH is intentionally not passed.
# App env vars are strings in serviceConfig.environmentVariables, reusing the
# same PORT/MATRIX_SIZE/STORAGE_DIR common.sh provides (as deploy-lambda.sh does).
BUILD_CONFIG="$(jq -n \
  --arg bucket "${WEBFN_S3_BUCKET}" \
  --arg key "${WEBFN_S3_KEY}" \
  --arg runtime "${WEBFN_RUNTIME}" \
  '{
     codeConfig: { s3Object: { bucket: $bucket, key: $key } },
     runtimeConfig: { runtime: $runtime }
   }')"

# shellcheck disable=SC2153 # STORAGE_DIR comes from the sourced common.sh, not a STAGE_DIR typo
# AWS_LAMBDA_NODEJS_ENTRYPOINT tells the native Node runtime our entry file is
# server.js (it defaults to index.js at the zip root otherwise). PORT is still
# passed for parity with the other targets, but the app prefers the runtime's
# injected AWS_LAMBDA_HTTP_ENDPOINT host:port when present, so PORT is a no-op
# on this target.
SERVICE_CONFIG="$(jq -n \
  --arg role "${ROLE_ARN}" \
  --argjson timeout "${WEBFN_REQUEST_TIMEOUT}" \
  --argjson concurrency "${WEBFN_MAX_CONCURRENCY_PER_ENV}" \
  --arg port "${PORT}" \
  --arg matrixSize "${MATRIX_SIZE}" \
  --arg storageDir "${STORAGE_DIR}" \
  --arg entrypoint "${WEBFN_NODEJS_ENTRYPOINT}" \
  '{
     executionRoleArn: $role,
     timeoutSeconds: $timeout,
     maxConcurrencyPerEnvironment: $concurrency,
     environmentVariables: {
       PORT: $port,
       MATRIX_SIZE: $matrixSize,
       STORAGE_DIR: $storageDir,
       AWS_LAMBDA_NODEJS_ENTRYPOINT: $entrypoint
     }
   }')"

# --- 5. Create (function+revision+endpoint) or add a revision --------------
if aws lambda-web get-web-function \
  --function-name "${WEBFN_FUNCTION_NAME}" \
  --region "${AWS_REGION}" >/dev/null 2>&1; then
  # UPDATE path: function exists, so add a new revision. autoDeploymentMode is
  # LatestRevision, so the endpoint promotes the new revision automatically.
  log "Web Function '${WEBFN_FUNCTION_NAME}' exists; creating a new revision"
  REVISION_ID="$(aws lambda-web create-web-function-revision \
    --cli-input-json "$(jq -n \
      --arg fn "${WEBFN_FUNCTION_NAME}" \
      --argjson build "${BUILD_CONFIG}" \
      --argjson service "${SERVICE_CONFIG}" \
      '{ functionName: $fn, buildConfig: $build, serviceConfig: $service }')" \
    --query 'revisionId' --output text \
    --region "${AWS_REGION}")"
  log "Created revision ${REVISION_ID}; LatestRevision endpoint will promote it"
else
  # CREATE path: one call provisions the function, its initial revision and the
  # HomeRegion endpoint together. Build the endpointConfig with the optional
  # scaling/throttle caps omitted unless their vars are non-empty (rateLimit=0
  # is a valid "disable" value, so gate on emptiness, not zeroness).
  ENDPOINT_CONFIG="$(jq -n \
    --arg name "${WEBFN_ENDPOINT_NAME}" \
    --arg type "${WEBFN_ENDPOINT_TYPE}" \
    '{
       endpointName: $name,
       endpointType: $type,
       authType: "ApplicationManaged",
       autoDeploymentMode: "LatestRevision"
     }')"
  if [ -n "${WEBFN_MAX_ENVIRONMENTS}" ]; then
    ENDPOINT_CONFIG="$(jq -n \
      --argjson ep "${ENDPOINT_CONFIG}" \
      --argjson maxEnv "${WEBFN_MAX_ENVIRONMENTS}" \
      '$ep + { scalingConfig: { maxEnvironments: $maxEnv } }')"
  fi
  if [ -n "${WEBFN_RATE_LIMIT}" ]; then
    ENDPOINT_CONFIG="$(jq -n \
      --argjson ep "${ENDPOINT_CONFIG}" \
      --argjson rate "${WEBFN_RATE_LIMIT}" \
      '$ep + { throttleConfig: { rateLimit: $rate } }')"
  fi

  log "Creating Web Function '${WEBFN_FUNCTION_NAME}' (function + revision + endpoint)"
  aws lambda-web create-web-function \
    --cli-input-json "$(jq -n \
      --arg fn "${WEBFN_FUNCTION_NAME}" \
      --argjson build "${BUILD_CONFIG}" \
      --argjson service "${SERVICE_CONFIG}" \
      --argjson endpoint "${ENDPOINT_CONFIG}" \
      '{
         functionName: $fn,
         revisionConfig: { buildConfig: $build, serviceConfig: $service },
         endpointConfig: $endpoint
       }')" \
    --region "${AWS_REGION}" >/dev/null
fi

# --- 6. Read the endpoint domain and print the URL (LAST line) -------------
# get-web-function-endpoint returns a bare `domainName` (no scheme), so prefix
# it with https:// to form the URL.
ENDPOINT_DOMAIN="$(aws lambda-web get-web-function-endpoint \
  --function-name "${WEBFN_FUNCTION_NAME}" \
  --endpoint-name "${WEBFN_ENDPOINT_NAME}" \
  --query 'domainName' --output text \
  --region "${AWS_REGION}")"

log "Done. Lambda Web Function endpoint:"
echo "https://${ENDPOINT_DOMAIN}"
