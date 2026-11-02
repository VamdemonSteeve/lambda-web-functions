#!/usr/bin/env bash
#
# Build the shared container image and push it to ECR.
# Idempotent: creates the ECR repo only if it is missing, always rebuilds and
# pushes the image at IMAGE_URI (see scripts/common.sh for config).
#
# Requires: AWS credentials, Docker.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

if [ -z "${AWS_ACCOUNT_ID}" ]; then
  echo "ERROR: could not resolve AWS account id (no valid credentials?)." >&2
  exit 1
fi

REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

log "Ensuring ECR repository '${ECR_REPO}' exists in ${AWS_REGION}"
if aws ecr describe-repositories \
  --repository-names "${ECR_REPO}" \
  --region "${AWS_REGION}" >/dev/null 2>&1; then
  log "ECR repository '${ECR_REPO}' already exists"
else
  log "Creating ECR repository '${ECR_REPO}'"
  aws ecr create-repository \
    --repository-name "${ECR_REPO}" \
    --image-scanning-configuration scanOnPush=true \
    --region "${AWS_REGION}" >/dev/null
fi

log "Logging Docker in to ${REGISTRY}"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

log "Building and pushing image ${IMAGE_URI} (linux/arm64) from ${REPO_ROOT}"
# Use `buildx ... --push` as a single step so this works regardless of the
# active buildx driver. The default `docker-container` driver does NOT load a
# plain `docker build` result into the local image store, which makes a
# separate `docker push` fail with "image not known"; pushing straight from
# buildx avoids that.
# Force a Docker v2 schema-2 manifest, NOT an OCI image index. Default buildx
# output is an OCI index with an attestation manifest, which AWS Lambda rejects
# on create/update-function-code ("image manifest ... media type is not
# supported"). --provenance=false drops the attestation and
# oci-mediatypes=false emits Docker media types that Lambda accepts. (ECS/Fargate
# and the webfn zip path are unaffected, but the shared image must stay
# Lambda-compatible.)
docker buildx build --platform linux/arm64 --provenance=false \
  --output type=image,oci-mediatypes=false,push=true \
  -t "${IMAGE_URI}" "${REPO_ROOT}"

log "Done. Pushed image:"
echo "${IMAGE_URI}"
