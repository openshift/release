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
  destroy_rc=0
  bin/hypershift destroy cluster aws \
    --aws-creds=${AWS_GUEST_INFRA_CREDENTIALS_FILE} \
    --name="${CLUSTER_NAME}" \
    --namespace="${HYPERSHIFT_NAMESPACE}" \
    --infra-id=${CLUSTER_NAME} \
    --base-domain=${DOMAIN} \
    --cluster-grace-period 40m || destroy_rc=$?
fi

# hypershift-setup-nested-management-cluster created this ConfigMap under a
# per-job name when HYPERSHIFT_MGMT_ADDITIONAL_TRUST_BUNDLE was set (see the
# comment there). "hypershift destroy cluster" deletes only the CLI secrets, so
# remove it here to keep the shared namespace clean.
if [[ "${CLOUD_PROVIDER}" != "Azure" && -n "${HYPERSHIFT_MGMT_ADDITIONAL_TRUST_BUNDLE:-}" ]]; then
  # Runs even if the destroy above failed, but deletes the ConfigMap only once
  # the HostedCluster is gone: while it exists it still references the
  # ConfigMap, and a later cleanup of the cluster needs a valid object.
  TRUST_BUNDLE_CONFIGMAP="${CLUSTER_NAME}-additional-trust-bundle"
  cleanup_rc=0
  if ! hc="$(oc get hostedcluster "${CLUSTER_NAME}" --namespace="${HYPERSHIFT_NAMESPACE}" --ignore-not-found -o name)"; then
    echo "Could not check HostedCluster ${HYPERSHIFT_NAMESPACE}/${CLUSTER_NAME}; keeping ConfigMap ${TRUST_BUNDLE_CONFIGMAP}" >&2
    cleanup_rc=1
  elif [[ -n "${hc}" ]]; then
    echo "HostedCluster ${HYPERSHIFT_NAMESPACE}/${CLUSTER_NAME} still exists; keeping ConfigMap ${TRUST_BUNDLE_CONFIGMAP} it references" >&2
  else
    oc delete configmap "${TRUST_BUNDLE_CONFIGMAP}" \
      --namespace="${HYPERSHIFT_NAMESPACE}" --ignore-not-found || cleanup_rc=$?
  fi
  # Report the destroy failure first; otherwise the cleanup result.
  if [[ "${destroy_rc:-0}" -eq 0 ]]; then
    destroy_rc="${cleanup_rc}"
  fi
fi
exit "${destroy_rc:-0}"
