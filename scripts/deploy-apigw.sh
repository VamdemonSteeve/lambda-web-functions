#!/usr/bin/env bash
#
# Deploy an AWS API Gateway HTTP API (apigatewayv2) as a single public front
# door routing by path prefix to BOTH deployments:
#
#   ANY /lambda/{proxy+}  -> AWS_PROXY  integration to the Lambda function
#   ANY /ecs/{proxy+}     -> HTTP_PROXY integration to the public ALB
#
# The backend apps have NO /lambda or /ecs route, so both integrations strip the
# prefix: a parameter mapping overwrites the request path with the captured
# {proxy} value (overwrite:path = /{proxy}). A request to /lambda/compute?n=64
# therefore reaches the app as /compute?n=64, and likewise for /ecs.
#
# Idempotent create-or-update. The ALB DNS + listener are discovered by ALB_NAME
# / listener port 80 (consistent with deploy-fargate.sh) rather than hardcoded.
#
# Requires: AWS credentials. The Lambda function and the ALB must already exist
# (run deploy-lambda.sh and deploy-fargate.sh first).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

if [ -z "${AWS_ACCOUNT_ID}" ]; then
  echo "ERROR: could not resolve AWS account id (no valid credentials?)." >&2
  exit 1
fi

LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${LAMBDA_FUNCTION_NAME}"

# --- 1. Discover the ALB DNS + :80 listener --------------------------------
log "Discovering ALB '${ALB_NAME}' DNS name"
ALB_DNS="$(aws elbv2 describe-load-balancers \
  --names "${ALB_NAME}" \
  --query 'LoadBalancers[0].DNSName' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
if [ -z "${ALB_DNS}" ] || [ "${ALB_DNS}" = "None" ]; then
  echo "ERROR: ALB '${ALB_NAME}' not found; run deploy-fargate.sh first." >&2
  exit 1
fi
log "Using ALB DNS ${ALB_DNS}"

# --- 1b. Discover the webfn endpoint domain (best-effort, non-fatal) -------
# The native Lambda Web Function endpoint domain is discovered at deploy time
# (not static config), mirroring deploy-webfn.sh. If webfn is not deployed yet
# the query returns empty/None and we SKIP the webfn route so lambda+ecs still
# deploy. WEBFN_ENDPOINT_NAME default mirrors deploy-webfn.sh (common.sh does
# not define it).
: "${WEBFN_ENDPOINT_NAME:=${WEBFN_FUNCTION_NAME}-endpoint}"
log "Discovering webfn endpoint '${WEBFN_ENDPOINT_NAME}' domain (best-effort)"
WEBFN_DOMAIN="$(aws lambda-web get-web-function-endpoint \
  --function-name "${WEBFN_FUNCTION_NAME}" \
  --endpoint-name "${WEBFN_ENDPOINT_NAME}" \
  --query 'domainName' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
if [ -z "${WEBFN_DOMAIN}" ] || [ "${WEBFN_DOMAIN}" = "None" ]; then
  log "webfn endpoint not found; skipping webfn route (run deploy-webfn.sh first)"
  WEBFN_DOMAIN=""
else
  log "Using webfn domain ${WEBFN_DOMAIN}"
fi

# --- 2. Find-or-create the HTTP API ----------------------------------------
log "Ensuring HTTP API '${APIGW_NAME}' exists"
API_ID="$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='${APIGW_NAME}'].ApiId | [0]" --output text --region "${AWS_REGION}" 2>/dev/null || true)"
if [ -z "${API_ID}" ] || [ "${API_ID}" = "None" ]; then
  log "Creating HTTP API '${APIGW_NAME}'"
  API_ID="$(aws apigatewayv2 create-api \
    --name "${APIGW_NAME}" \
    --protocol-type HTTP \
    --query 'ApiId' --output text --region "${AWS_REGION}")"
else
  log "HTTP API '${APIGW_NAME}' already exists (${API_ID}), reusing"
fi

# --- 3. Lambda AWS_PROXY integration (payload 2.0, path -> /{proxy}) -------
# Reuse an existing integration to the same function if present; otherwise
# create it. Looked up by IntegrationUri matching the function ARN.
log "Ensuring Lambda AWS_PROXY integration"
LAMBDA_INTEG_ID="$(aws apigatewayv2 get-integrations \
  --api-id "${API_ID}" \
  --query "Items[?IntegrationUri=='${LAMBDA_ARN}'].IntegrationId | [0]" \
  --output text --region "${AWS_REGION}" 2>/dev/null || true)"
# JSON form of the path-overwrite mapping. The shorthand key=value parser in
# the AWS CLI chokes on the '}' in the ${request.path.proxy} stage variable, so
# request-parameters are passed as JSON.
PATH_OVERWRITE_JSON='{"overwrite:path":"/${request.path.proxy}"}'
if [ -z "${LAMBDA_INTEG_ID}" ] || [ "${LAMBDA_INTEG_ID}" = "None" ]; then
  log "Creating Lambda integration"
  LAMBDA_INTEG_ID="$(aws apigatewayv2 create-integration \
    --api-id "${API_ID}" \
    --integration-type AWS_PROXY \
    --integration-uri "${LAMBDA_ARN}" \
    --payload-format-version 2.0 \
    --request-parameters "${PATH_OVERWRITE_JSON}" \
    --query 'IntegrationId' --output text --region "${AWS_REGION}")"
else
  log "Lambda integration already exists (${LAMBDA_INTEG_ID}); updating path mapping"
  aws apigatewayv2 update-integration \
    --api-id "${API_ID}" \
    --integration-id "${LAMBDA_INTEG_ID}" \
    --integration-type AWS_PROXY \
    --integration-uri "${LAMBDA_ARN}" \
    --payload-format-version 2.0 \
    --request-parameters "${PATH_OVERWRITE_JSON}" \
    --region "${AWS_REGION}" >/dev/null
fi

# --- 4. ALB HTTP_PROXY integration (ANY, uri -> http://alb/{proxy}) --------
# The integration URI embeds the {proxy} substitution so API Gateway forwards
# only the matched proxy path to the ALB.
ALB_INTEG_URI="http://${ALB_DNS}/{proxy}"
log "Ensuring ALB HTTP_PROXY integration -> ${ALB_INTEG_URI}"
ALB_INTEG_ID="$(aws apigatewayv2 get-integrations \
  --api-id "${API_ID}" \
  --query "Items[?IntegrationUri=='${ALB_INTEG_URI}'].IntegrationId | [0]" \
  --output text --region "${AWS_REGION}" 2>/dev/null || true)"
if [ -z "${ALB_INTEG_ID}" ] || [ "${ALB_INTEG_ID}" = "None" ]; then
  log "Creating ALB integration"
  ALB_INTEG_ID="$(aws apigatewayv2 create-integration \
    --api-id "${API_ID}" \
    --integration-type HTTP_PROXY \
    --integration-method ANY \
    --integration-uri "${ALB_INTEG_URI}" \
    --payload-format-version 1.0 \
    --request-parameters "${PATH_OVERWRITE_JSON}" \
    --query 'IntegrationId' --output text --region "${AWS_REGION}")"
else
  log "ALB integration already exists (${ALB_INTEG_ID}); updating"
  aws apigatewayv2 update-integration \
    --api-id "${API_ID}" \
    --integration-id "${ALB_INTEG_ID}" \
    --integration-type HTTP_PROXY \
    --integration-method ANY \
    --integration-uri "${ALB_INTEG_URI}" \
    --payload-format-version 1.0 \
    --request-parameters "${PATH_OVERWRITE_JSON}" \
    --region "${AWS_REGION}" >/dev/null
fi

# --- 4b. webfn HTTP_PROXY integration (ANY, uri -> https://webfn/{proxy}) --
# Mirrors the ALB HTTP_PROXY integration exactly, but over HTTPS. The webfn
# endpoint is authType=ApplicationManaged so no SigV4 signing / IAM permission
# is required — API Gateway proxies to it as a plain HTTPS origin. Only built
# when the webfn domain was discovered above.
if [ -n "${WEBFN_DOMAIN}" ]; then
  WEBFN_INTEG_URI="https://${WEBFN_DOMAIN}/{proxy}"
  log "Ensuring webfn HTTP_PROXY integration -> ${WEBFN_INTEG_URI}"
  WEBFN_INTEG_ID="$(aws apigatewayv2 get-integrations \
    --api-id "${API_ID}" \
    --query "Items[?IntegrationUri=='${WEBFN_INTEG_URI}'].IntegrationId | [0]" \
    --output text --region "${AWS_REGION}" 2>/dev/null || true)"
  if [ -z "${WEBFN_INTEG_ID}" ] || [ "${WEBFN_INTEG_ID}" = "None" ]; then
    log "Creating webfn integration"
    WEBFN_INTEG_ID="$(aws apigatewayv2 create-integration \
      --api-id "${API_ID}" \
      --integration-type HTTP_PROXY \
      --integration-method ANY \
      --integration-uri "${WEBFN_INTEG_URI}" \
      --payload-format-version 1.0 \
      --request-parameters "${PATH_OVERWRITE_JSON}" \
      --query 'IntegrationId' --output text --region "${AWS_REGION}")"
  else
    log "webfn integration already exists (${WEBFN_INTEG_ID}); updating"
    aws apigatewayv2 update-integration \
      --api-id "${API_ID}" \
      --integration-id "${WEBFN_INTEG_ID}" \
      --integration-type HTTP_PROXY \
      --integration-method ANY \
      --integration-uri "${WEBFN_INTEG_URI}" \
      --payload-format-version 1.0 \
      --request-parameters "${PATH_OVERWRITE_JSON}" \
      --region "${AWS_REGION}" >/dev/null
  fi
fi

# --- 5. Routes --------------------------------------------------------------
# create-or-reuse a route by key, pointing it at the given integration.
ensure_route() {
  local route_key="$1" integ_id="$2" rid
  rid="$(aws apigatewayv2 get-routes \
    --api-id "${API_ID}" \
    --query "Items[?RouteKey=='${route_key}'].RouteId | [0]" \
    --output text --region "${AWS_REGION}" 2>/dev/null || true)"
  if [ -z "${rid}" ] || [ "${rid}" = "None" ]; then
    log "Creating route '${route_key}'"
    aws apigatewayv2 create-route \
      --api-id "${API_ID}" \
      --route-key "${route_key}" \
      --target "integrations/${integ_id}" \
      --region "${AWS_REGION}" >/dev/null
  else
    log "Route '${route_key}' already exists (${rid}); ensuring target"
    aws apigatewayv2 update-route \
      --api-id "${API_ID}" \
      --route-id "${rid}" \
      --target "integrations/${integ_id}" \
      --region "${AWS_REGION}" >/dev/null
  fi
}

ensure_route 'ANY /lambda/{proxy+}' "${LAMBDA_INTEG_ID}"
ensure_route 'ANY /ecs/{proxy+}' "${ALB_INTEG_ID}"
if [ -n "${WEBFN_DOMAIN}" ]; then
  ensure_route 'ANY /webfn/{proxy+}' "${WEBFN_INTEG_ID}"
fi

# --- 6. $default stage with auto-deploy ------------------------------------
log "Ensuring '\$default' stage exists with auto-deploy on"
if aws apigatewayv2 get-stage \
  --api-id "${API_ID}" \
  --stage-name '$default' \
  --region "${AWS_REGION}" >/dev/null 2>&1; then
  log "Stage '\$default' already exists, reusing"
else
  log "Creating '\$default' stage"
  aws apigatewayv2 create-stage \
    --api-id "${API_ID}" \
    --stage-name '$default' \
    --auto-deploy \
    --region "${AWS_REGION}" >/dev/null
fi

# --- 7. Lambda invoke permission for API Gateway ---------------------------
# Source ARN scoped to this API (any stage/method/path). Idempotent.
log "Ensuring API Gateway may invoke '${LAMBDA_FUNCTION_NAME}'"
aws lambda add-permission \
  --function-name "${LAMBDA_FUNCTION_NAME}" \
  --statement-id "apigw-${APIGW_NAME}-invoke" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${AWS_REGION}:${AWS_ACCOUNT_ID}:${API_ID}/*/*" \
  --region "${AWS_REGION}" >/dev/null 2>&1 \
  || log "Invoke permission already present, skipping"

# --- 8. Output --------------------------------------------------------------
INVOKE_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com"

log "Done. HTTP API invoke URL:"
echo "${INVOKE_URL}"
echo ""
log "Usable base URLs:"
echo "  Lambda: ${INVOKE_URL}/lambda"
echo "  ECS:    ${INVOKE_URL}/ecs"
if [ -n "${WEBFN_DOMAIN}" ]; then
  echo "  webfn:  ${INVOKE_URL}/webfn"
fi
