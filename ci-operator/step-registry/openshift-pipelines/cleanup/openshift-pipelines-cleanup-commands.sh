#!/bin/bash

# Best-effort cleanup — intentionally no set -o errexit
set -o nounset
set -o pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

LABEL_SELECTOR="openshift-pipelines.tekton.dev/test=true"

# Collect all namespaces that carry the test label
mapfile -t TEST_NAMESPACES < <(oc get namespace -l "${LABEL_SELECTOR}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

if [[ "${CLEANUP_PIPELINERUNS}" == "true" ]]; then
  echo "Cleaning up PipelineRuns in labelled namespaces..."
  for ns in "${TEST_NAMESPACES[@]}"; do
    [[ -z "${ns}" ]] && continue
    echo "  Deleting PipelineRuns in namespace: ${ns}"
    oc delete pipelineruns --all -n "${ns}" --ignore-not-found=true || \
      echo "WARNING: failed to delete PipelineRuns in namespace ${ns}" >&2
  done
fi

if [[ "${CLEANUP_PVCS}" == "true" ]]; then
  echo "Cleaning up PersistentVolumeClaims in labelled namespaces..."
  for ns in "${TEST_NAMESPACES[@]}"; do
    [[ -z "${ns}" ]] && continue
    echo "  Deleting PVCs in namespace: ${ns}"
    oc delete pvc --all -n "${ns}" --ignore-not-found=true || \
      echo "WARNING: failed to delete PVCs in namespace ${ns}" >&2
  done
fi

if [[ "${CLEANUP_NAMESPACES}" == "true" ]]; then
  echo "Cleaning up labelled test namespaces..."
  for ns in "${TEST_NAMESPACES[@]}"; do
    [[ -z "${ns}" ]] && continue
    echo "  Deleting namespace: ${ns}"
    oc delete namespace "${ns}" --ignore-not-found=true --wait=false || \
      echo "WARNING: failed to delete namespace ${ns}" >&2
    oc wait namespace "${ns}" --for=delete --timeout=120s || \
      echo "WARNING: timed out waiting for namespace ${ns} to be deleted" >&2
  done
fi

echo "Cleanup complete."
