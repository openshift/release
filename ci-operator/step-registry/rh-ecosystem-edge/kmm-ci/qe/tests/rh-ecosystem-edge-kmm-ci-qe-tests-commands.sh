#!/bin/bash

set -euo pipefail

export ECO_TEST_FEATURES="${ECO_TEST_FEATURES:-modules}"
export ECO_TEST_LABELS="${ECO_TEST_LABELS:-module && !kmm-longrun}"
export ECO_TEST_TIMEOUT="${ECO_TEST_TIMEOUT:-80m}"
export ECO_TEST_VERBOSE="${ECO_TEST_VERBOSE:-true}"
export ECO_HWACCEL_KMM_DEVICE_PLUGIN_IMAGE="${ECO_HWACCEL_KMM_DEVICE_PLUGIN_IMAGE:-quay.io/cvultur/device-plugin:latest-%s}"
export ECO_HWACCEL_KMM_REGISTRY="${ECO_HWACCEL_KMM_REGISTRY:-quay.io/ocp-edge-qe}"

if [[ -z "${ECO_HWACCEL_KMM_PULL_SECRET:-}" ]]; then
  pull_secret_file="${ECO_HWACCEL_KMM_PULL_SECRET_FILE:-/var/run/secrets/ci-pull-credentials/.dockerconfigjson}"
  if [[ ! -r "${pull_secret_file}" ]]; then
    echo "KMM pull-secret file is not readable: ${pull_secret_file}" >&2
    exit 1
  fi

  ECO_HWACCEL_KMM_PULL_SECRET="$(jq -er --arg registry "${ECO_HWACCEL_KMM_REGISTRY%%/*}" \
    '.auths[$registry].auth // empty' "${pull_secret_file}")"
  export ECO_HWACCEL_KMM_PULL_SECRET
fi

mkdir -p "${ARTIFACT_DIR}"
oc version || true
{
  echo "ready_status:"
  oc get nodes \
    -o custom-columns='READY:.status.conditions[?(@.type=="Ready")].status'
} > "${ARTIFACT_DIR}/nodes.txt" 2>&1 || true

set +e
./scripts/test-runner.sh \
  --junit-report=junit-kmm.xml \
  --json-report=ginkgo-kmm.json \
  --output-dir="${ARTIFACT_DIR}"

test_rc="$?"

oc get modules.kmm.sigs.x-k8s.io --all-namespaces \
  -o custom-columns='MODULE_LOADER_AVAILABLE:.status.moduleLoader.availableNumber,MODULE_LOADER_DESIRED:.status.moduleLoader.desiredNumber,DEVICE_PLUGIN_AVAILABLE:.status.devicePlugin.availableNumber,DEVICE_PLUGIN_DESIRED:.status.devicePlugin.desiredNumber' \
  > "${ARTIFACT_DIR}/kmm-modules.yaml" 2>&1 || true
oc get pods --namespace openshift-kmm \
  -o custom-columns='PHASE:.status.phase,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount' \
  > "${ARTIFACT_DIR}/kmm-pods.txt" 2>&1 || true
oc get events --namespace openshift-kmm --sort-by=.lastTimestamp \
  -o custom-columns='TYPE:.type,REASON:.reason,COUNT:.count,LAST:.lastTimestamp' \
  > "${ARTIFACT_DIR}/kmm-events.txt" 2>&1 || true
oc get csv --namespace openshift-kmm \
  -o custom-columns='PHASE:.status.phase,REASON:.status.reason' \
  > "${ARTIFACT_DIR}/kmm-csvs.yaml" 2>&1 || true

exit "${test_rc}"
