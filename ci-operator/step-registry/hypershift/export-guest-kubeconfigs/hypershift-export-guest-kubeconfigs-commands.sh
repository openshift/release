#!/bin/bash

set -euo pipefail

# Kubeconfigs contain cluster credentials; keep generated files private to the owner.
umask 077

export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"
HYPERSHIFT_BINARY="${HYPERSHIFT_BINARY:-/hypershift/bin/hypershift}"
CLUSTER_MANIFEST="${SHARED_DIR}/cluster-manifests.json"

if [[ ! -s "${KUBECONFIG}" ]]; then
  echo "Management cluster kubeconfig not found at ${KUBECONFIG}" >&2
  exit 1
fi

if [[ ! -s "${CLUSTER_MANIFEST}" ]]; then
  echo "Cluster manifest not found at ${CLUSTER_MANIFEST}" >&2
  exit 1
fi

if ! jq -e '.clusters | type == "array" and length > 0' "${CLUSTER_MANIFEST}" >/dev/null; then
  echo "Cluster manifest does not contain a non-empty clusters array: ${CLUSTER_MANIFEST}" >&2
  exit 1
fi

cluster_count=0
while IFS=$'\t' read -r cluster_name cluster_namespace; do
  if [[ -z "${cluster_name}" || -z "${cluster_namespace}" ]]; then
    echo "Cluster manifest contains an entry without a name or namespace" >&2
    exit 1
  fi

  output="${SHARED_DIR}/${cluster_name}_kubeconfig"
  temporary="${output}.tmp"

  echo "Exporting kubeconfig for hosted cluster ${cluster_namespace}/${cluster_name} to ${output}"
  rm -f -- "${temporary}"
  "${HYPERSHIFT_BINARY}" create kubeconfig \
    --name="${cluster_name}" \
    --namespace="${cluster_namespace}" \
    > "${temporary}"

  if [[ ! -s "${temporary}" ]]; then
    echo "Generated kubeconfig for ${cluster_namespace}/${cluster_name} is empty" >&2
    rm -f -- "${temporary}"
    exit 1
  fi

  mv -- "${temporary}" "${output}"
  chmod 600 "${output}"
  cluster_count=$((cluster_count + 1))
done < <(jq -r '.clusters[] | [.name, .namespace] | @tsv' "${CLUSTER_MANIFEST}")

if (( cluster_count == 0 )); then
  echo "No hosted clusters found in ${CLUSTER_MANIFEST}" >&2
  exit 1
fi

echo "Exported ${cluster_count} hosted cluster kubeconfig(s)"
