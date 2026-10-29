#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Cleans up after rosa-conf-vpc-cni: removes the IRSA IAM role and detaches
# the ECR read-only policy the standard deprovision chain does not know
# about. All in-cluster changes (the SCCs, the helm release and the tuning
# config) are removed with the cluster by rosa-cluster-deprovision.

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# AWS credentials from the cluster profile; without them the aws iam calls
# below would fail unauthenticated.
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
else
  log "ERROR: no ${AWSCRED} in the cluster profile; cannot configure the AWS CLI"
  exit 1
fi

# ---- Detach the ECR read-only policy from the worker role ----
# Attached by rosa-conf-vpc-cni so the nodes can pull the CNI images from
# Amazon's private ECR. The worker role itself is created and deleted by
# rosa-sts-account-roles-create/delete, but detach anyway in case the role
# outlives the job (shared account roles): leaving the policy attached grants
# the role ECR read access it was not provisioned with.
if [[ -s "${SHARED_DIR}/aws-vpc-cni-worker-role-arn" ]]; then
  WORKER_ROLE_ARN=$(cat "${SHARED_DIR}/aws-vpc-cni-worker-role-arn")
  if err=$(aws iam detach-role-policy \
    --role-name "${WORKER_ROLE_ARN##*/}" \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly 2>&1); then
    log "Detached AmazonEC2ContainerRegistryReadOnly from ${WORKER_ROLE_ARN}"
  elif grep -qE 'NoSuchEntity|PolicyAttachmentNotFound|was not found' <<<"${err}"; then
    log "ECR policy already detached or role ${WORKER_ROLE_ARN##*/} gone"
  else
    log "ERROR: cannot detach ECR policy from ${WORKER_ROLE_ARN}: ${err}"
    exit 1
  fi
fi

# ---- Delete the IRSA role ----
if [[ ! -s "${SHARED_DIR}/aws-vpc-cni-role-name" ]]; then
  log "No aws-vpc-cni-role-name in ${SHARED_DIR}; nothing to do"
  exit 0
fi
IAM_ROLE_NAME=$(cat "${SHARED_DIR}/aws-vpc-cni-role-name")

# Only a NoSuchEntity get-role failure means the role is already gone; any
# other failure (credentials, throttling, network) must fail the step rather
# than silently delete the marker and leak the role.
if err=$(aws iam get-role --role-name "${IAM_ROLE_NAME}" 2>&1 >/dev/null); then
  aws iam detach-role-policy \
    --role-name "${IAM_ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy || true
  aws iam delete-role --role-name "${IAM_ROLE_NAME}"
  log "Deleted IAM role ${IAM_ROLE_NAME}"
elif grep -q 'NoSuchEntity' <<<"${err}"; then
  log "IAM role ${IAM_ROLE_NAME} already gone"
else
  log "ERROR: cannot query IAM role ${IAM_ROLE_NAME}: ${err}"
  exit 1
fi
