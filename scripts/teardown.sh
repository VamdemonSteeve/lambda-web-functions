#!/usr/bin/env bash
#
# Tear down the lambda-web-functions deployments.
#
# Usage: teardown.sh <lambda|fargate|apigw|webfn|all> [--delete-ecr]
#
# Every destructive call is non-fatal: if a resource is already gone the script
# prints a skip message and keeps going (idempotent). Only networking THIS
# project created (the dedicated SG) is removed; the default VPC/subnets are
# never touched. The webfn target additionally removes its dedicated execution
# role (WEBFN_ROLE_NAME); the lambda target likewise removes LAMBDA_ROLE_NAME.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  echo "Usage: $(basename "$0") <lambda|fargate|apigw|webfn|all> [--delete-ecr]" >&2
  exit 2
}

TARGET="${1:-}"
DELETE_ECR="false"
if [ "${2:-}" = "--delete-ecr" ]; then
  DELETE_ECR="true"
fi

case "${TARGET}" in
  lambda|fargate|apigw|webfn|all) ;;
  *) usage ;;
esac

LOG_GROUP="/ecs/${FARGATE_TASKDEF}"
EXEC_ROLE_NAME="ecsTaskExecutionRole"

# --- Lambda teardown --------------------------------------------------------
teardown_lambda() {
  log "Deleting Function URL config for '${LAMBDA_FUNCTION_NAME}'"
  aws lambda delete-function-url-config \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --region "${AWS_REGION}" 2>/dev/null \
    || log "Function URL config not found, skipping"

  log "Deleting function '${LAMBDA_FUNCTION_NAME}'"
  aws lambda delete-function \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --region "${AWS_REGION}" 2>/dev/null \
    || log "Function not found, skipping"

  log "Detaching policy from role '${LAMBDA_ROLE_NAME}'"
  aws iam detach-role-policy \
    --role-name "${LAMBDA_ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null \
    || log "Policy not attached / role missing, skipping"

  log "Deleting role '${LAMBDA_ROLE_NAME}'"
  aws iam delete-role \
    --role-name "${LAMBDA_ROLE_NAME}" 2>/dev/null \
    || log "Role not found, skipping"
}

# --- Fargate teardown -------------------------------------------------------
teardown_fargate() {
  log "Scaling service '${FARGATE_SERVICE}' to 0"
  aws ecs update-service \
    --cluster "${FARGATE_CLUSTER}" \
    --service "${FARGATE_SERVICE}" \
    --desired-count 0 \
    --region "${AWS_REGION}" >/dev/null 2>&1 \
    || log "Service not found, skipping scale-down"

  log "Deleting service '${FARGATE_SERVICE}'"
  aws ecs delete-service \
    --cluster "${FARGATE_CLUSTER}" \
    --service "${FARGATE_SERVICE}" \
    --force \
    --region "${AWS_REGION}" >/dev/null 2>&1 \
    || log "Service not found, skipping"

  log "Deregistering all task definition revisions for '${FARGATE_TASKDEF}'"
  local arns
  arns="$(aws ecs list-task-definitions \
    --family-prefix "${FARGATE_TASKDEF}" \
    --query 'taskDefinitionArns[]' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
  if [ -n "${arns}" ] && [ "${arns}" != "None" ]; then
    for arn in ${arns}; do
      log "Deregistering ${arn}"
      aws ecs deregister-task-definition \
        --task-definition "${arn}" \
        --region "${AWS_REGION}" >/dev/null 2>&1 \
        || log "Could not deregister ${arn}, skipping"
    done
  else
    log "No task definitions found, skipping"
  fi

  # ALB + listener + target group
  local alb_arn listener_arn tg_arn
  alb_arn="$(aws elbv2 describe-load-balancers \
    --names "${ALB_NAME}" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
  if [ -n "${alb_arn}" ] && [ "${alb_arn}" != "None" ]; then
    # shellcheck disable=SC2016 # backticks are JMESPath literals, not shell expansion
    listener_arn="$(aws elbv2 describe-listeners \
      --load-balancer-arn "${alb_arn}" \
      --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
    if [ -n "${listener_arn}" ] && [ "${listener_arn}" != "None" ]; then
      log "Deleting listener :80"
      aws elbv2 delete-listener \
        --listener-arn "${listener_arn}" \
        --region "${AWS_REGION}" 2>/dev/null \
        || log "Listener not found, skipping"
    else
      log "No :80 listener found, skipping"
    fi

    log "Deleting ALB '${ALB_NAME}'"
    aws elbv2 delete-load-balancer \
      --load-balancer-arn "${alb_arn}" \
      --region "${AWS_REGION}" 2>/dev/null \
      || log "ALB not found, skipping"
    log "Waiting for ALB deletion"
    aws elbv2 wait load-balancers-deleted \
      --load-balancer-arns "${alb_arn}" --region "${AWS_REGION}" 2>/dev/null \
      || log "ALB wait skipped"
  else
    log "ALB '${ALB_NAME}' not found, skipping"
  fi

  tg_arn="$(aws elbv2 describe-target-groups \
    --names "${TG_NAME}" \
    --query 'TargetGroups[0].TargetGroupArn' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
  if [ -n "${tg_arn}" ] && [ "${tg_arn}" != "None" ]; then
    log "Deleting target group '${TG_NAME}'"
    aws elbv2 delete-target-group \
      --target-group-arn "${tg_arn}" \
      --region "${AWS_REGION}" 2>/dev/null \
      || log "Target group not found, skipping"
  else
    log "Target group '${TG_NAME}' not found, skipping"
  fi

  # Dedicated SG (created by deploy-fargate.sh). Default VPC/subnets untouched.
  local vpc_id sg_id
  vpc_id="$(aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
  if [ -n "${vpc_id}" ] && [ "${vpc_id}" != "None" ]; then
    sg_id="$(aws ec2 describe-security-groups \
      --filters "Name=group-name,Values=${FARGATE_SG_NAME}" "Name=vpc-id,Values=${vpc_id}" \
      --query 'SecurityGroups[0].GroupId' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
    if [ -n "${sg_id}" ] && [ "${sg_id}" != "None" ]; then
      log "Deleting dedicated security group '${FARGATE_SG_NAME}' (${sg_id})"
      aws ec2 delete-security-group \
        --group-id "${sg_id}" \
        --region "${AWS_REGION}" 2>/dev/null \
        || log "Security group in use or not found, skipping"
    else
      log "Security group '${FARGATE_SG_NAME}' not found, skipping"
    fi
  fi

  log "Deleting CloudWatch log group '${LOG_GROUP}'"
  aws logs delete-log-group \
    --log-group-name "${LOG_GROUP}" \
    --region "${AWS_REGION}" 2>/dev/null \
    || log "Log group not found, skipping"

  log "Deleting ECS cluster '${FARGATE_CLUSTER}'"
  aws ecs delete-cluster \
    --cluster "${FARGATE_CLUSTER}" \
    --region "${AWS_REGION}" >/dev/null 2>&1 \
    || log "Cluster not found, skipping"

  # Note: ecsTaskExecutionRole is a shared, account-wide role and is left in
  # place on purpose (other workloads may depend on it).
  log "Leaving shared role '${EXEC_ROLE_NAME}' in place (account-wide)"
}

# --- API Gateway teardown ---------------------------------------------------
teardown_apigw() {
  local api_id
  api_id="$(aws apigatewayv2 get-apis \
    --query "Items[?Name=='${APIGW_NAME}'].ApiId | [0]" \
    --output text --region "${AWS_REGION}" 2>/dev/null || true)"
  if [ -n "${api_id}" ] && [ "${api_id}" != "None" ]; then
    log "Deleting HTTP API '${APIGW_NAME}' (${api_id})"
    aws apigatewayv2 delete-api \
      --api-id "${api_id}" \
      --region "${AWS_REGION}" 2>/dev/null \
      || log "HTTP API not found, skipping"
  else
    log "HTTP API '${APIGW_NAME}' not found, skipping"
  fi

  log "Removing API Gateway invoke permission from '${LAMBDA_FUNCTION_NAME}'"
  aws lambda remove-permission \
    --function-name "${LAMBDA_FUNCTION_NAME}" \
    --statement-id "apigw-${APIGW_NAME}-invoke" \
    --region "${AWS_REGION}" 2>/dev/null \
    || log "Invoke permission not present, skipping"
}

# --- webfn (Lambda Web Function) teardown -----------------------------------
# Delete in dependency order: endpoint -> revision(s) -> web function -> role.
# Every call is non-fatal so a re-run after partial teardown stays idempotent.
teardown_webfn() {
  # First remove the shared API Gateway webfn route + its HTTP_PROXY
  # integration so re-running teardown then deploy is clean. `teardown_apigw`
  # deletes the whole API, but tearing down ONLY `webfn` must not leave a
  # dangling /webfn route. Narrowly scoped, idempotent, non-fatal: find the
  # API by APIGW_NAME, delete the 'ANY /webfn/{proxy+}' route (capturing its
  # Target integration id first, since the webfn domain may already be gone),
  # then delete that integration.
  local wf_api_id wf_route_id wf_integ_ref wf_integ_id
  wf_api_id="$(aws apigatewayv2 get-apis \
    --query "Items[?Name=='${APIGW_NAME}'].ApiId | [0]" \
    --output text --region "${AWS_REGION}" 2>/dev/null || true)"
  if [ -n "${wf_api_id}" ] && [ "${wf_api_id}" != "None" ]; then
    wf_route_id="$(aws apigatewayv2 get-routes \
      --api-id "${wf_api_id}" \
      --query "Items[?RouteKey=='ANY /webfn/{proxy+}'].RouteId | [0]" \
      --output text --region "${AWS_REGION}" 2>/dev/null || true)"
    if [ -n "${wf_route_id}" ] && [ "${wf_route_id}" != "None" ]; then
      # Capture the route Target (e.g. "integrations/<id>") before deleting the
      # route so we can remove the now-orphaned integration regardless of
      # whether the webfn domain still resolves.
      wf_integ_ref="$(aws apigatewayv2 get-route \
        --api-id "${wf_api_id}" \
        --route-id "${wf_route_id}" \
        --query 'Target' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
      log "Deleting API Gateway route 'ANY /webfn/{proxy+}' (${wf_route_id})"
      aws apigatewayv2 delete-route \
        --api-id "${wf_api_id}" \
        --route-id "${wf_route_id}" \
        --region "${AWS_REGION}" 2>/dev/null \
        || log "webfn route not found, skipping"
      wf_integ_id="${wf_integ_ref##*/}"
      if [ -n "${wf_integ_id}" ] && [ "${wf_integ_id}" != "None" ] && [ "${wf_integ_ref}" != "None" ]; then
        log "Deleting webfn HTTP_PROXY integration (${wf_integ_id})"
        aws apigatewayv2 delete-integration \
          --api-id "${wf_api_id}" \
          --integration-id "${wf_integ_id}" \
          --region "${AWS_REGION}" 2>/dev/null \
          || log "webfn integration not found, skipping"
      else
        log "No webfn integration target found, skipping"
      fi
    else
      log "API Gateway route 'ANY /webfn/{proxy+}' not found, skipping"
    fi
  else
    log "HTTP API '${APIGW_NAME}' not found, skipping webfn route removal"
  fi

  # Web Functions live under the SEPARATE `aws lambda-web` service, not
  # `aws lambda`. Delete endpoint(s) -> revision(s) -> function.
  log "Deleting all endpoints for '${WEBFN_FUNCTION_NAME}'"
  local endpoints
  endpoints="$(aws lambda-web list-web-function-endpoints \
    --function-name "${WEBFN_FUNCTION_NAME}" \
    --query 'endpoints[].endpointName' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
  if [ -n "${endpoints}" ] && [ "${endpoints}" != "None" ]; then
    for ep in ${endpoints}; do
      log "Deleting endpoint ${ep}"
      aws lambda-web delete-web-function-endpoint \
        --function-name "${WEBFN_FUNCTION_NAME}" \
        --endpoint-name "${ep}" \
        --region "${AWS_REGION}" 2>/dev/null \
        || log "Could not delete endpoint ${ep}, skipping"
    done
  else
    log "No endpoints found, skipping"
  fi

  log "Deleting all revisions for '${WEBFN_FUNCTION_NAME}'"
  local revs
  revs="$(aws lambda-web list-web-function-revisions \
    --function-name "${WEBFN_FUNCTION_NAME}" \
    --query 'revisions[].revisionId' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
  if [ -n "${revs}" ] && [ "${revs}" != "None" ]; then
    for rev in ${revs}; do
      log "Deleting revision ${rev}"
      aws lambda-web delete-web-function-revision \
        --function-name "${WEBFN_FUNCTION_NAME}" \
        --revision-id "${rev}" \
        --region "${AWS_REGION}" 2>/dev/null \
        || log "Could not delete ${rev}, skipping"
    done
  else
    log "No revisions found, skipping"
  fi

  log "Deleting Web Function '${WEBFN_FUNCTION_NAME}'"
  aws lambda-web delete-web-function \
    --function-name "${WEBFN_FUNCTION_NAME}" \
    --region "${AWS_REGION}" 2>/dev/null \
    || log "Web Function not found, skipping"

  log "Detaching policy from role '${WEBFN_ROLE_NAME}'"
  aws iam detach-role-policy \
    --role-name "${WEBFN_ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null \
    || log "Policy not attached / role missing, skipping"

  log "Deleting role '${WEBFN_ROLE_NAME}'"
  aws iam delete-role \
    --role-name "${WEBFN_ROLE_NAME}" 2>/dev/null \
    || log "Role not found, skipping"
}

# --- Shared: ECR ------------------------------------------------------------
teardown_ecr() {
  log "Deleting ECR repository '${ECR_REPO}' (--force)"
  aws ecr delete-repository \
    --repository-name "${ECR_REPO}" \
    --force \
    --region "${AWS_REGION}" 2>/dev/null \
    || log "ECR repository not found, skipping"
}

case "${TARGET}" in
  lambda) teardown_lambda ;;
  fargate) teardown_fargate ;;
  apigw) teardown_apigw ;;
  webfn) teardown_webfn ;;
  all) teardown_apigw; teardown_lambda; teardown_webfn; teardown_fargate ;;
esac

if [ "${DELETE_ECR}" = "true" ]; then
  teardown_ecr
fi

log "Teardown complete for target '${TARGET}'."
