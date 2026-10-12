#!/bin/bash

# Set cloud-specific kubeconfig
if [[ "${CLOUD_PROVIDER}" == "Azure" ]]; then
  export KUBECONFIG=/etc/hypershift-kubeconfig-azure/hypershift-ops-admin.kubeconfig
else
  export KUBECONFIG=/etc/hypershift-kubeconfig/hypershift-ops-admin.kubeconfig
fi

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
mkdir -p "${ARTIFACT_DIR}/output"
bin/hypershift dump cluster --dump-guest-cluster=true --artifact-dir="${ARTIFACT_DIR}/output" --name="${CLUSTER_NAME}" --namespace="${HYPERSHIFT_NAMESPACE}"

# Azure dump logs trigger leaktk/gcs-filter censoring of tarballs; skip tarring for Azure
# so individual files upload directly and only the sensitive ones get censored
if [[ "${CLOUD_PROVIDER}" != "Azure" ]]; then
  tar -cvzf "${ARTIFACT_DIR}/artifacts.tar.gz" "${ARTIFACT_DIR}/output"
  rm -rf "${ARTIFACT_DIR}/output"
fi
