#!/usr/bin/env bash
#
# Deploy the shared image to AWS Lambda as a classic Lambda (LWA) function (via
# the Lambda Web Adapter baked into the image). Idempotent create-or-update.
# NOTE: "Lambda Web Function" (the native webfn target, see deploy-webfn.sh) is a
# DIFFERENT thing — this script is the classic adapter-based Lambda, not that.
#
# Exposes a Function URL with --auth-type NONE and --invoke-mode RESPONSE_STREAM
# so the /stream endpoint genuinely streams (and TTFB is measurable).
# Sizing (memory, ephemeral storage) and app env vars come from common.sh so the
# Lambda and Fargate deployments stay matched.
#
# Requires: AWS credentials. Image must already be pushed (run build-and-push.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

if [ -z "${AWS_ACCOUNT_ID}" ]; then
  echo "ERROR: could not resolve AWS account id (no valid credentials?)." >&2
  exit 1
fi

ROLE_ARN=""

# --- 1. Execution role ------------------------------------------------------
log "Ensuring Lambda execution role '${LAMBDA_ROLE_NAME}' exists"
if aws iam get-role --role-name "${LAMBDA_ROLE_NAME}" >/dev/null 2>&1; then
  log "Role '${LAMBDA_ROLE_NAME}' already exists, reusing"
else
  log "Creating role '${LAMBDA_ROLE_NAME}'"
  aws iam create-role \
    --role-name "${LAMBDA_ROLE_NAME}" \
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
  log "Attaching AWSLambdaBasicExecutionRole to '${LAMBDA_ROLE_NAME}'"
  aws iam attach-role-policy \
    --role-name "${LAMBDA_ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  log "Waiting for IAM role to propagate"
  sleep 10
fi
ROLE_ARN="$(aws iam get-role --role-name "${LAMBDA_ROLE_NAME}" --query 'Role.Arn' --output text)"

# --- 2. Function create-or-update ------------------------------------------
ENV_VARS="Variables={PORT=${PORT},MATRIX_SIZE=${MATRIX_SIZE},STORAGE_DIR=${STORAGE_DIR}}"

if aws lambda get-function \
  --function-name "${LAMBDA_FUNCTION_NAME}" \
  --region "${AWS_REGION}" >/dev/null 2>&1; then
  log "Function '${LAMBDA_FUNCTION_NAME}' exists; updating code"
  aws lambda update-function-code \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --image-uri "${IMAGE_URI}" \
    --architectures arm64 \
    --region "${AWS_REGION}" >/dev/null
  log "Waiting for code update to settle"
  aws lambda wait function-updated \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --region "${AWS_REGION}"

  log "Updating function configuration (memory/ephemeral/env)"
  aws lambda update-function-configuration \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --memory-size "${LAMBDA_MEMORY_MB}" \
    --ephemeral-storage "Size=${LAMBDA_EPHEMERAL_MB}" \
    --environment "${ENV_VARS}" \
    --region "${AWS_REGION}" >/dev/null
  aws lambda wait function-updated \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --region "${AWS_REGION}"
else
  log "Creating function '${LAMBDA_FUNCTION_NAME}'"
  aws lambda create-function \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --package-type Image \
    --code "ImageUri=${IMAGE_URI}" \
    --architectures arm64 \
    --role "${ROLE_ARN}" \
    --memory-size "${LAMBDA_MEMORY_MB}" \
    --ephemeral-storage "Size=${LAMBDA_EPHEMERAL_MB}" \
    --environment "${ENV_VARS}" \
    --timeout 60 \
    --region "${AWS_REGION}" >/dev/null
  log "Waiting for function to become active"
  aws lambda wait function-active-v2 \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --region "${AWS_REGION}"
fi

# --- 3. Function URL (streaming, no auth) ----------------------------------
if aws lambda get-function-url-config \
  --function-name "${LAMBDA_FUNCTION_NAME}" \
  --region "${AWS_REGION}" >/dev/null 2>&1; then
  log "Updating Function URL config (auth NONE, invoke-mode RESPONSE_STREAM)"
  aws lambda update-function-url-config \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --auth-type NONE \
    --invoke-mode RESPONSE_STREAM \
    --region "${AWS_REGION}" >/dev/null
else
  log "Creating Function URL config (auth NONE, invoke-mode RESPONSE_STREAM)"
  aws lambda create-function-url-config \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --auth-type NONE \
    --invoke-mode RESPONSE_STREAM \
    --region "${AWS_REGION}" >/dev/null
fi

# Public invoke permission for the Function URL. Idempotent: ignore if present.
log "Ensuring public invoke permission for the Function URL"
aws lambda add-permission \
  --function-name "${LAMBDA_FUNCTION_NAME}" \
  --statement-id FunctionURLAllowPublicAccess \
  --action lambda:InvokeFunctionUrl \
  --principal '*' \
  --function-url-auth-type NONE \
  --region "${AWS_REGION}" >/dev/null 2>&1 \
  || log "Invoke permission already present, skipping"

FUNCTION_URL="$(aws lambda get-function-url-config \
  --function-name "${LAMBDA_FUNCTION_NAME}" \
  --query 'FunctionUrl' --output text \
  --region "${AWS_REGION}")"

log "Done. Lambda Function URL:"
echo "${FUNCTION_URL}"
