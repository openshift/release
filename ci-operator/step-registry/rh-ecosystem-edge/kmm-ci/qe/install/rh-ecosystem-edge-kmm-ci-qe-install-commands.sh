#!/bin/bash

set -euo pipefail

collect_cluster_diagnostics() {
  local diagnostics_dir="${ARTIFACT_DIR:-/tmp/artifacts}/kmm-diagnostics"
  mkdir -p "${diagnostics_dir}"

  run_diagnostic() {
    local name="$1"
    shift
    local output="${diagnostics_dir}/${name}"
    echo "Collecting ${name}: $*" >&2
    if "$@" >"${output}" 2>&1; then
      echo "Saved ${output}" >&2
    else
      local status=$?
      echo "Command exited with ${status}; saved ${output}" >&2
    fi
  }

  run_diagnostic context.txt date -u
  run_diagnostic oc-version.txt oc version
  run_diagnostic cluster-version.yaml oc get clusterversion version -o yaml
  run_diagnostic infrastructure.yaml oc get infrastructure cluster -o yaml
  run_diagnostic cluster-operators.yaml oc get clusteroperators -o yaml
  run_diagnostic nodes.yaml oc get nodes -o wide
  run_diagnostic non-running-pods.txt oc get pods --all-namespaces \
    --field-selector=status.phase!=Running -o wide
  run_diagnostic node-descriptions.txt oc describe nodes
  run_diagnostic machine-config-pools.yaml oc get machineconfigpools -o yaml
  run_diagnostic network-operator.yaml oc get network.operator.openshift.io cluster -o yaml
  run_diagnostic image-config.yaml oc get image.config.openshift.io cluster -o yaml
  run_diagnostic image-content-source-policies.yaml oc get imagecontentsourcepolicies -o yaml
  run_diagnostic image-digest-mirror-sets.yaml oc get imagedigestmirrorsets -o yaml

  run_diagnostic olm-resources.yaml oc get deployment,daemonset,pod,service,endpoints \
    --namespace openshift-operator-lifecycle-manager -o wide
  run_diagnostic marketplace-resources.yaml oc get deployment,daemonset,pod,service,endpoints \
    --namespace openshift-marketplace -o wide
  run_diagnostic olm-api-resources.txt oc api-resources --api-group operators.coreos.com
  run_diagnostic package-api-resources.txt oc api-resources --api-group packages.operators.coreos.com
  run_diagnostic olm-events.txt oc get events --namespace openshift-operator-lifecycle-manager \
    --sort-by='.lastTimestamp'
  run_diagnostic marketplace-events.txt oc get events --namespace openshift-marketplace \
    --sort-by='.lastTimestamp'
  run_diagnostic warning-events.txt oc get events --all-namespaces \
    --field-selector type=Warning --sort-by='.lastTimestamp'

  run_diagnostic catalogsources.yaml oc get catalogsources \
    --namespace openshift-marketplace -o yaml
  run_diagnostic kmm-catalogsource.yaml oc get catalogsource kmm-konflux \
    --namespace openshift-marketplace -o yaml
  run_diagnostic kmm-catalogsource-description.txt oc describe catalogsource kmm-konflux \
    --namespace openshift-marketplace
  run_diagnostic kmm-catalogsource-events.txt oc get events --all-namespaces \
    --field-selector involvedObject.name=kmm-konflux --sort-by='.lastTimestamp'
  run_diagnostic kmm-catalog-pull-secret-metadata.txt oc get secret kmm-catalog-pull-secret \
    --namespace openshift-marketplace \
    -o go-template='type={{.type}}{{"\n"}}{{range $key, $value := .data}}key={{$key}} bytes={{len $value}}{{"\n"}}{{end}}'

  run_diagnostic kmm-resources.yaml oc get subscription,csv,installplan,operatorgroup,all \
    --namespace openshift-kmm -o yaml
  run_diagnostic kmm-events.txt oc get events --namespace openshift-kmm \
    --sort-by='.lastTimestamp'

  for deployment in catalog-operator olm-operator packageserver; do
    run_diagnostic "${deployment}.log" oc logs "deployment/${deployment}" \
      --namespace openshift-operator-lifecycle-manager --all-containers=true \
      --prefix=true --since=30m
    run_diagnostic "${deployment}-previous.log" oc logs "deployment/${deployment}" \
      --namespace openshift-operator-lifecycle-manager --all-containers=true \
      --prefix=true --previous
  done

  run_diagnostic marketplace-operator.log oc logs deployment/marketplace-operator \
    --namespace openshift-marketplace --all-containers=true \
    --prefix=true --since=30m
  run_diagnostic marketplace-operator-previous.log oc logs deployment/marketplace-operator \
    --namespace openshift-marketplace --all-containers=true \
    --prefix=true --previous

  for namespace in openshift-ovn-kubernetes openshift-network-operator openshift-multus; do
    run_diagnostic "${namespace}-pods.txt" oc get pods --namespace "${namespace}" -o wide
    run_diagnostic "${namespace}-events.txt" oc get events --namespace "${namespace}" \
      --sort-by='.lastTimestamp'
  done

  catalog_pods="$(oc get pods --namespace openshift-marketplace \
    --selector olm.catalogSource=kmm-konflux -o name 2>/dev/null || true)"
  if [[ -z "${catalog_pods}" ]]; then
    printf '%s\n' 'No CatalogSource pods found for kmm-konflux' \
      >"${diagnostics_dir}/kmm-catalogsource-pods.txt"
  else
    while IFS= read -r pod; do
      [[ -z "${pod}" ]] && continue
      pod_name="${pod#pod/}"
      run_diagnostic "${pod_name}-describe.txt" oc describe "${pod}" \
        --namespace openshift-marketplace
      run_diagnostic "${pod_name}.log" oc logs "${pod}" \
        --namespace openshift-marketplace --all-containers=true --prefix=true
      run_diagnostic "${pod_name}-previous.log" oc logs "${pod}" \
        --namespace openshift-marketplace --all-containers=true --prefix=true --previous
    done <<< "${catalog_pods}"
  fi

  echo "Comprehensive KMM diagnostics saved under ${diagnostics_dir}" >&2
}

if [[ -n "${KMM_QE_DEBUG_SLEEP:-}" ]]; then
  echo "KMM QE debug pause: sleeping ${KMM_QE_DEBUG_SLEEP} before KMM installation"
  sleep "${KMM_QE_DEBUG_SLEEP}"
fi

if ! KMM_CHANNEL="${KMM_CHANNEL:-release-2.7}" \
  KMM_CATALOG_PULL_SECRET_PATH="${KMM_CATALOG_PULL_SECRET_PATH:-}" \
  make cluster-operators; then
  collect_cluster_diagnostics
  exit 1
fi
