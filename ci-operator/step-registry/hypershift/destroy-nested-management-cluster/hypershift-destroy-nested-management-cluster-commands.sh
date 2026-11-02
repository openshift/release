#!/bin/bash
set -euo pipefail

# Set cloud-specific defaults
if [[ "${CLOUD_PROVIDER}" == "Azure" ]]; then
  export KUBECONFIG=/etc/hypershift-kubeconfig-azure/hypershift-ops-admin.kubeconfig
  AZURE_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-self-managed-azure/credentials.json"
  DEFAULT_BASE_DOMAIN=hypershift.azure.devcluster.openshift.com
else
  AWS_GUEST_INFRA_CREDENTIALS_FILE="/etc/hypershift-ci-jobs-awscreds/credentials"
  DEFAULT_BASE_DOMAIN=ci.hypershift.devcluster.openshift.com
  export KUBECONFIG=/etc/hypershift-kubeconfig/hypershift-ops-admin.kubeconfig

  if [[ $HYPERSHIFT_GUEST_INFRA_OCP_ACCOUNT == "true" ]]; then
    AWS_GUEST_INFRA_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
    DEFAULT_BASE_DOMAIN=origin-ci-int-aws.dev.rhcloud.com
  fi
fi

DOMAIN=${HYPERSHIFT_BASE_DOMAIN:-$DEFAULT_BASE_DOMAIN}
CLUSTER_NAME_PREFIX="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-10)"
if [[ -n "${HYPERSHIFT_CLUSTER_ROLE}" ]]; then
  if [[ ! "${HYPERSHIFT_CLUSTER_ROLE}" =~ ^[a-z0-9-]+$ ]]; then
    echo "HYPERSHIFT_CLUSTER_ROLE must contain only lowercase letters, digits, or hyphens" >&2
    exit 1
  fi
  CLUSTER_NAME="${CLUSTER_NAME_PREFIX}-${HYPERSHIFT_CLUSTER_ROLE}-mgmt"
else
  CLUSTER_NAME="${CLUSTER_NAME_PREFIX}-mgmt"
fi

# Destroy the management cluster based on cloud provider
if [[ "${CLOUD_PROVIDER}" == "Azure" ]]; then
  echo "Destroying Azure management cluster ${CLUSTER_NAME}"
  bin/hypershift destroy cluster azure \
    --azure-creds=${AZURE_GUEST_INFRA_CREDENTIALS_FILE} \
    --name="${CLUSTER_NAME}" \
    --namespace="${HYPERSHIFT_NAMESPACE}" \
    --location=${HYPERSHIFT_AZURE_LOCATION} \
    --dns-zone-rg-name=os4-common \
    --cluster-grace-period 40m
else
  echo "Destroying AWS management cluster ${CLUSTER_NAME}"
  bin/hypershift destroy cluster aws \
    --aws-creds=${AWS_GUEST_INFRA_CREDENTIALS_FILE} \
    --name="${CLUSTER_NAME}" \
    --namespace="${HYPERSHIFT_NAMESPACE}" \
    --infra-id=${CLUSTER_NAME} \
    --base-domain=${DOMAIN} \
    --cluster-grace-period 40m
fi
