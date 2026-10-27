#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Deletes the IRSA role created by rosa-conf-vpc-cni. The standard
# rosa-aws-sts-hcp-deprovision chain does not know about this extra role and
# would leak it.

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

if [[ ! -s "${SHARED_DIR}/aws-vpc-cni-role-name" ]]; then
  log "No aws-vpc-cni-role-name in ${SHARED_DIR}; nothing to do"
  exit 0
fi
IAM_ROLE_NAME=$(cat "${SHARED_DIR}/aws-vpc-cni-role-name")

if aws iam get-role --role-name "${IAM_ROLE_NAME}" >/dev/null 2>&1; then
  aws iam detach-role-policy \
    --role-name "${IAM_ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy || true
  aws iam delete-role --role-name "${IAM_ROLE_NAME}"
  log "Deleted IAM role ${IAM_ROLE_NAME}"
else
  log "IAM role ${IAM_ROLE_NAME} already gone"
fi
rm -f "${SHARED_DIR}/aws-vpc-cni-role-name"
