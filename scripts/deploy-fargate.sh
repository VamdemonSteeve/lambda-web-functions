#!/usr/bin/env bash
#
# Deploy the shared image to ECS Fargate behind an internet-facing ALB.
# Idempotent create-or-update. Uses the account's default VPC/subnets (never
# modifies them) and creates a single dedicated security group for this project.
#
# Sizing (cpu/memory) and app env vars come from common.sh so the Lambda and
# Fargate deployments stay matched. Listener :80 forwards to container port 8080
# with /health as the health check.
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

LOG_GROUP="/ecs/${FARGATE_TASKDEF}"
EXEC_ROLE_NAME="ecsTaskExecutionRole"

# --- 1. Networking: default VPC + public subnets ---------------------------
log "Discovering default VPC"
VPC_ID="$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "${AWS_REGION}")"
if [ -z "${VPC_ID}" ] || [ "${VPC_ID}" = "None" ]; then
  echo "ERROR: no default VPC found in ${AWS_REGION}." >&2
  exit 1
fi
log "Using default VPC ${VPC_ID}"

log "Discovering subnets in ${VPC_ID}"
SUBNET_IDS="$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
  --query 'Subnets[].SubnetId' --output text --region "${AWS_REGION}")"
if [ -z "${SUBNET_IDS}" ]; then
  echo "ERROR: no default subnets found in ${VPC_ID}." >&2
  exit 1
fi
# Comma-separated for the ALB call; space-separated for the ECS network config.
SUBNET_CSV="$(echo "${SUBNET_IDS}" | tr '[:space:]' ',' | sed 's/,$//')"
log "Using subnets: ${SUBNET_CSV}"

# --- 2. Dedicated security group -------------------------------------------
log "Ensuring security group '${FARGATE_SG_NAME}' exists"
SG_ID="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${FARGATE_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
if [ -z "${SG_ID}" ] || [ "${SG_ID}" = "None" ]; then
  log "Creating security group '${FARGATE_SG_NAME}'"
  SG_ID="$(aws ec2 create-security-group \
    --group-name "${FARGATE_SG_NAME}" \
    --description "lambda-web-functions Fargate SG" \
    --vpc-id "${VPC_ID}" \
    --query 'GroupId' --output text --region "${AWS_REGION}")"
  log "Authorizing inbound TCP 80 from 0.0.0.0/0 on ${SG_ID}"
  aws ec2 authorize-security-group-ingress \
    --group-id "${SG_ID}" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 \
    --region "${AWS_REGION}" >/dev/null 2>&1 \
    || log "Ingress rule already present, skipping"
  # Allow the ALB (same SG) to reach the container port.
  aws ec2 authorize-security-group-ingress \
    --group-id "${SG_ID}" \
    --protocol tcp --port "${CONTAINER_PORT}" --cidr 0.0.0.0/0 \
    --region "${AWS_REGION}" >/dev/null 2>&1 \
    || log "Container-port ingress rule already present, skipping"
else
  log "Security group '${FARGATE_SG_NAME}' already exists (${SG_ID}), reusing"
fi

# --- 3. CloudWatch log group -----------------------------------------------
log "Ensuring CloudWatch log group '${LOG_GROUP}' exists"
aws logs create-log-group \
  --log-group-name "${LOG_GROUP}" \
  --region "${AWS_REGION}" >/dev/null 2>&1 \
  || log "Log group already exists, skipping"

# --- 4. ECS task execution role --------------------------------------------
log "Ensuring '${EXEC_ROLE_NAME}' exists"
if aws iam get-role --role-name "${EXEC_ROLE_NAME}" >/dev/null 2>&1; then
  log "Role '${EXEC_ROLE_NAME}' already exists, reusing"
else
  log "Creating role '${EXEC_ROLE_NAME}'"
  aws iam create-role \
    --role-name "${EXEC_ROLE_NAME}" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": { "Service": "ecs-tasks.amazonaws.com" },
          "Action": "sts:AssumeRole"
        }
      ]
    }' >/dev/null
  aws iam attach-role-policy \
    --role-name "${EXEC_ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
  log "Waiting for IAM role to propagate"
  sleep 10
fi
EXEC_ROLE_ARN="$(aws iam get-role --role-name "${EXEC_ROLE_NAME}" --query 'Role.Arn' --output text)"

# --- 5. Task definition -----------------------------------------------------
log "Registering task definition '${FARGATE_TASKDEF}'"
CONTAINER_DEFS="$(cat <<JSON
[
  {
    "name": "${FARGATE_TASKDEF}",
    "image": "${IMAGE_URI}",
    "essential": true,
    "portMappings": [
      { "containerPort": ${CONTAINER_PORT}, "protocol": "tcp" }
    ],
    "environment": [
      { "name": "PORT", "value": "${PORT}" },
      { "name": "MATRIX_SIZE", "value": "${MATRIX_SIZE}" },
      { "name": "STORAGE_DIR", "value": "${STORAGE_DIR}" }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "${LOG_GROUP}",
        "awslogs-region": "${AWS_REGION}",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }
]
JSON
)"

TASKDEF_ARN="$(aws ecs register-task-definition \
  --family "${FARGATE_TASKDEF}" \
  --requires-compatibilities FARGATE \
  --network-mode awsvpc \
  --cpu "${FARGATE_CPU}" \
  --memory "${FARGATE_MEMORY}" \
  --execution-role-arn "${EXEC_ROLE_ARN}" \
  --runtime-platform "cpuArchitecture=ARM64,operatingSystemFamily=LINUX" \
  --container-definitions "${CONTAINER_DEFS}" \
  --query 'taskDefinition.taskDefinitionArn' --output text \
  --region "${AWS_REGION}")"
log "Registered ${TASKDEF_ARN}"

# --- 6. ECS cluster ---------------------------------------------------------
log "Ensuring ECS cluster '${FARGATE_CLUSTER}' exists"
CLUSTER_STATUS="$(aws ecs describe-clusters \
  --clusters "${FARGATE_CLUSTER}" \
  --query 'clusters[0].status' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
if [ "${CLUSTER_STATUS}" = "ACTIVE" ]; then
  log "Cluster '${FARGATE_CLUSTER}' already active, reusing"
else
  log "Creating cluster '${FARGATE_CLUSTER}'"
  aws ecs create-cluster \
    --cluster-name "${FARGATE_CLUSTER}" \
    --region "${AWS_REGION}" >/dev/null
fi

# --- 7. ALB -----------------------------------------------------------------
log "Ensuring ALB '${ALB_NAME}' exists"
ALB_ARN="$(aws elbv2 describe-load-balancers \
  --names "${ALB_NAME}" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
if [ -z "${ALB_ARN}" ] || [ "${ALB_ARN}" = "None" ]; then
  log "Creating internet-facing ALB '${ALB_NAME}'"
  # shellcheck disable=SC2086 # intentional word-splitting of subnet ids
  ALB_ARN="$(aws elbv2 create-load-balancer \
    --name "${ALB_NAME}" \
    --type application \
    --scheme internet-facing \
    --subnets ${SUBNET_IDS} \
    --security-groups "${SG_ID}" \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text \
    --region "${AWS_REGION}")"
  log "Waiting for ALB to become available"
  aws elbv2 wait load-balancer-available \
    --load-balancer-arns "${ALB_ARN}" --region "${AWS_REGION}"
else
  log "ALB '${ALB_NAME}' already exists, reusing"
fi

# --- 8. Target group --------------------------------------------------------
log "Ensuring target group '${TG_NAME}' exists"
TG_ARN="$(aws elbv2 describe-target-groups \
  --names "${TG_NAME}" \
  --query 'TargetGroups[0].TargetGroupArn' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
if [ -z "${TG_ARN}" ] || [ "${TG_ARN}" = "None" ]; then
  log "Creating target group '${TG_NAME}' (ip, HTTP ${CONTAINER_PORT}, health /health)"
  TG_ARN="$(aws elbv2 create-target-group \
    --name "${TG_NAME}" \
    --protocol HTTP \
    --port "${CONTAINER_PORT}" \
    --vpc-id "${VPC_ID}" \
    --target-type ip \
    --health-check-protocol HTTP \
    --health-check-path /health \
    --query 'TargetGroups[0].TargetGroupArn' --output text \
    --region "${AWS_REGION}")"
else
  log "Target group '${TG_NAME}' already exists, reusing"
fi

# --- 9. Listener :80 -> target group ---------------------------------------
log "Ensuring listener :80 forwards to '${TG_NAME}'"
# shellcheck disable=SC2016 # backticks are JMESPath literals, not shell expansion
LISTENER_ARN="$(aws elbv2 describe-listeners \
  --load-balancer-arn "${ALB_ARN}" \
  --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
if [ -z "${LISTENER_ARN}" ] || [ "${LISTENER_ARN}" = "None" ]; then
  log "Creating listener on :80"
  aws elbv2 create-listener \
    --load-balancer-arn "${ALB_ARN}" \
    --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
    --region "${AWS_REGION}" >/dev/null
else
  log "Listener on :80 already exists; ensuring it forwards to '${TG_NAME}'"
  aws elbv2 modify-listener \
    --listener-arn "${LISTENER_ARN}" \
    --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
    --region "${AWS_REGION}" >/dev/null
fi

# --- 10. Service create-or-update ------------------------------------------
NETWORK_CONFIG="awsvpcConfiguration={subnets=[${SUBNET_CSV}],securityGroups=[${SG_ID}],assignPublicIp=ENABLED}"
LB_CONFIG="targetGroupArn=${TG_ARN},containerName=${FARGATE_TASKDEF},containerPort=${CONTAINER_PORT}"

SERVICE_STATUS="$(aws ecs describe-services \
  --cluster "${FARGATE_CLUSTER}" \
  --services "${FARGATE_SERVICE}" \
  --query 'services[0].status' --output text --region "${AWS_REGION}" 2>/dev/null || true)"
if [ "${SERVICE_STATUS}" = "ACTIVE" ]; then
  log "Service '${FARGATE_SERVICE}' exists; updating to new task definition"
  aws ecs update-service \
    --cluster "${FARGATE_CLUSTER}" \
    --service "${FARGATE_SERVICE}" \
    --task-definition "${TASKDEF_ARN}" \
    --desired-count 1 \
    --region "${AWS_REGION}" >/dev/null
else
  log "Creating service '${FARGATE_SERVICE}'"
  aws ecs create-service \
    --cluster "${FARGATE_CLUSTER}" \
    --service-name "${FARGATE_SERVICE}" \
    --task-definition "${TASKDEF_ARN}" \
    --desired-count 1 \
    --launch-type FARGATE \
    --network-configuration "${NETWORK_CONFIG}" \
    --load-balancers "${LB_CONFIG}" \
    --region "${AWS_REGION}" >/dev/null
fi

ALB_DNS="$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "${ALB_ARN}" \
  --query 'LoadBalancers[0].DNSName' --output text --region "${AWS_REGION}")"

log "Done. Fargate app reachable at (allow a minute for health checks):"
echo "http://${ALB_DNS}"
