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
HC_REGION=${HYPERSHIFT_AWS_REGION:-$LEASED_RESOURCE}

if [[ $HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT == "true" ]]; then
  AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
  DEFAULT_BASE_DOMAIN=origin-ci-int-aws.dev.rhcloud.com

  # A cluster profile set (for example openshift-org-aws) leases an account and
  # a region together; hypershift-aws-create created the cluster there.
  if [[ -n "${CLUSTER_PROFILE_SET_NAME:-}" ]]; then
    if [[ -r "${CLUSTER_PROFILE_DIR}/baseDomain" ]]; then
      DEFAULT_BASE_DOMAIN="$(< "${CLUSTER_PROFILE_DIR}/baseDomain")"
    fi
    HC_REGION="${LEASED_RESOURCE}"
  fi
fi
DOMAIN=${HYPERSHIFT_BASE_DOMAIN:-$DEFAULT_BASE_DOMAIN}

CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
echo "$(date) Deleting HyperShift cluster ${CLUSTER_NAME}"
bin/hypershift destroy cluster aws \
  --aws-creds=${AWS_GUEST_INFRA_CREDENTIALS_FILE}  \
  --name ${CLUSTER_NAME} \
  --region ${HC_REGION} \
  --base-domain ${DOMAIN} \
  --cluster-grace-period 40m
echo "$(date) Finished deleting cluster"
