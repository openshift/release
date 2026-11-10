#!/bin/bash

set -euo pipefail

export ECO_TEST_FEATURES="${ECO_TEST_FEATURES:-modules}"
export ECO_TEST_LABELS="${ECO_TEST_LABELS:-module && !kmm-longrun}"
export ECO_TEST_TIMEOUT="${ECO_TEST_TIMEOUT:-80m}"
export ECO_TEST_VERBOSE="${ECO_TEST_VERBOSE:-true}"
export ECO_HWACCEL_KMM_DEVICE_PLUGIN_IMAGE="${ECO_HWACCEL_KMM_DEVICE_PLUGIN_IMAGE:-quay.io/cvultur/device-plugin:latest-%s}"
export ECO_HWACCEL_KMM_REGISTRY="${ECO_HWACCEL_KMM_REGISTRY:-quay.io/ocp-edge-qe}"

if [[ -z "${ECO_HWACCEL_KMM_PULL_SECRET:-}" ]]; then
  pull_secret_file="${ECO_HWACCEL_KMM_PULL_SECRET_FILE:-/var/run/secrets/kmm-quay-push/kmm-pull-secret}"
  if [[ ! -r "${pull_secret_file}" ]]; then
    echo "KMM pull-secret file is not readable: ${pull_secret_file}" >&2
    exit 1
  fi

  ECO_HWACCEL_KMM_PULL_SECRET="$(tr -d '\r\n' < "${pull_secret_file}")"
  if [[ -z "${ECO_HWACCEL_KMM_PULL_SECRET}" ]]; then
    echo "The KMM pull-secret file is empty: ${pull_secret_file}" >&2
    exit 1
  fi
  export ECO_HWACCEL_KMM_PULL_SECRET
fi

mkdir -p "${ARTIFACT_DIR}"
oc version || true
{
  echo "ready_status:"
  oc get nodes \
    -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'
} > "${ARTIFACT_DIR}/nodes.txt" 2>&1 || true

if [[ -n "${KMM_QE_DEBUG_SLEEP:-}" ]]; then
  echo "KMM QE debug pause: sleeping ${KMM_QE_DEBUG_SLEEP} before starting the test suite"
  sleep "${KMM_QE_DEBUG_SLEEP}"
fi

set +e
./scripts/test-runner.sh \
  --junit-report=junit-kmm.xml \
  --json-report=ginkgo-kmm.json \
  --output-dir="${ARTIFACT_DIR}"

test_rc="$?"

oc get modules.kmm.sigs.x-k8s.io --all-namespaces \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,MODULE_LOADER_AVAILABLE:.status.moduleLoader.availableNumber,MODULE_LOADER_DESIRED:.status.moduleLoader.desiredNumber,DEVICE_PLUGIN_AVAILABLE:.status.devicePlugin.availableNumber,DEVICE_PLUGIN_DESIRED:.status.devicePlugin.desiredNumber' \
  > "${ARTIFACT_DIR}/kmm-modules.yaml" 2>&1 || true
oc get pods --all-namespaces \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,REASON:.status.reason,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount' \
  > "${ARTIFACT_DIR}/kmm-pods.txt" 2>&1 || true
oc get events --all-namespaces --sort-by=.lastTimestamp \
  -o custom-columns='NAMESPACE:.metadata.namespace,LAST:.lastTimestamp,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.kind/.involvedObject.name,MESSAGE:.message' \
  > "${ARTIFACT_DIR}/kmm-events.txt" 2>&1 || true
oc get csv --namespace openshift-kmm \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,REASON:.status.reason' \
  > "${ARTIFACT_DIR}/kmm-csvs.yaml" 2>&1 || true

{
  echo "Failed or build pod diagnostics:"
  while IFS=$'\t' read -r namespace name phase; do
    [[ -n "${namespace}" && -n "${name}" ]] || continue
    if [[ "${phase}" == "Failed" || "${name}" == *-build ]]; then
      echo
      echo "===== ${namespace}/${name} (${phase}) ====="
      oc describe pod "${name}" --namespace "${namespace}" || true
      oc logs "${name}" --namespace "${namespace}" --all-containers --tail=200 || true
    fi
  done < <(
    oc get pods --all-namespaces \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' \
      2>/dev/null || true
  )
} > "${ARTIFACT_DIR}/build-pod-diagnostics.txt" 2>&1 || true

exit "${test_rc}"
