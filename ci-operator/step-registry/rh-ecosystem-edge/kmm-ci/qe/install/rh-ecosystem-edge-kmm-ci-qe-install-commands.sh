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
  oc get events --all-namespaces \
    --field-selector involvedObject.name=kmm-konflux \
    --sort-by='.lastTimestamp' >&2 || true

  echo "KMM CatalogSource pull-secret metadata:" >&2
  oc get secret kmm-catalog-pull-secret \
    --namespace openshift-marketplace \
    -o go-template='type={{.type}}{{"\n"}}{{range $key, $value := .data}}key={{$key}} bytes={{len $value}}{{"\n"}}{{end}}' >&2 || true

  echo "Marketplace operator pods:" >&2
  oc get pods --namespace openshift-marketplace \
    --selector app=marketplace-operator -o wide >&2 || true
  echo "Marketplace operator logs (last 20 minutes):" >&2
  oc logs deployment/marketplace-operator \
    --namespace openshift-marketplace --all-containers=true \
    --prefix=true --since=20m >&2 || true
  echo "Marketplace operator previous logs:" >&2
  oc logs deployment/marketplace-operator \
    --namespace openshift-marketplace --all-containers=true \
    --prefix=true --previous >&2 || true

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
