#!/bin/bash

set -euo pipefail

print_marketplace_failure_diagnostics() {
  echo "Marketplace/CatalogSource diagnostics:" >&2
  oc get catalogsource kmm-konflux \
    --namespace openshift-marketplace -o yaml >&2 || true
  oc describe catalogsource kmm-konflux \
    --namespace openshift-marketplace >&2 || true
  oc get pods --namespace openshift-marketplace \
    --selector olm.catalogSource=kmm-konflux -o wide >&2 || true
  oc get events --namespace openshift-marketplace \
    --sort-by='.lastTimestamp' >&2 || true

  catalog_pods="$(oc get pods --namespace openshift-marketplace \
    --selector olm.catalogSource=kmm-konflux -o name 2>/dev/null || true)"
  if [[ -z "${catalog_pods}" ]]; then
    echo "No CatalogSource pods found for kmm-konflux" >&2
    return
  fi

  while IFS= read -r pod; do
    [[ -z "${pod}" ]] && continue
    oc describe "${pod}" --namespace openshift-marketplace >&2 || true
    oc logs "${pod}" --namespace openshift-marketplace \
      --all-containers=true --prefix=true >&2 || true
    oc logs "${pod}" --namespace openshift-marketplace \
      --all-containers=true --prefix=true --previous >&2 || true
  done <<< "${catalog_pods}"
}

if ! KMM_CHANNEL="${KMM_CHANNEL:-release-2.7}" \
  KMM_CATALOG_PULL_SECRET_PATH="${KMM_CATALOG_PULL_SECRET_PATH:-}" \
  make cluster-operators; then
  print_marketplace_failure_diagnostics
  exit 1
fi
