#!/bin/bash

set -exuo pipefail

if [[ -n "${HYPERSHIFT_CLUSTER_ROLE:-}" ]]; then
  if [[ ! "${HYPERSHIFT_CLUSTER_ROLE}" =~ ^[a-z0-9-]+$ ]]; then
    echo "HYPERSHIFT_CLUSTER_ROLE must contain only lowercase letters, digits, or hyphens" >&2
    exit 1
  fi
  export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig_${HYPERSHIFT_CLUSTER_ROLE}"
  if [[ ! -s "${KUBECONFIG}" ]]; then
    echo "Management cluster kubeconfig ${KUBECONFIG} is missing or empty" >&2
    exit 1
  fi
fi

AWS_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"
DEFAULT_BASE_DOMAIN=ci.hypershift.devcluster.openshift.com

if [[ $HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT == "true" ]]; then
  AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
  DEFAULT_BASE_DOMAIN=origin-ci-int-aws.dev.rhcloud.com
fi
DOMAIN=${HYPERSHIFT_BASE_DOMAIN:-$DEFAULT_BASE_DOMAIN}
HC_REGION=${HYPERSHIFT_AWS_REGION:-$LEASED_RESOURCE}

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
echo "$(date) Deleting HyperShift cluster ${CLUSTER_NAME}"
bin/hypershift destroy cluster aws \
  --aws-creds=${AWS_GUEST_INFRA_CREDENTIALS_FILE}  \
  --name ${CLUSTER_NAME} \
  --region ${HC_REGION} \
  --base-domain ${DOMAIN} \
  --cluster-grace-period 40m
echo "$(date) Finished deleting cluster"
