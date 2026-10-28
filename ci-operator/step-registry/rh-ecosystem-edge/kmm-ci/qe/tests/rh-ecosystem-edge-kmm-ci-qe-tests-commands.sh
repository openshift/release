#!/bin/bash

set -euo pipefail

export ECO_TEST_FEATURES="${ECO_TEST_FEATURES:-modules}"
export ECO_TEST_LABELS="${ECO_TEST_LABELS:-module && !kmm-longrun}"
export ECO_TEST_TIMEOUT="${ECO_TEST_TIMEOUT:-80m}"
export ECO_TEST_VERBOSE="${ECO_TEST_VERBOSE:-true}"
export ECO_HWACCEL_KMM_DEVICE_PLUGIN_IMAGE="${ECO_HWACCEL_KMM_DEVICE_PLUGIN_IMAGE:-quay.io/cvultur/device-plugin:latest-%s}"

mkdir -p "${ARTIFACT_DIR}"
oc version || true
{
  echo "ready_status:"
  oc get nodes -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
} > "${ARTIFACT_DIR}/nodes.txt" 2>&1 || true

set +e
ginkgo --label-filter="${ECO_TEST_LABELS}" \
  --timeout="${ECO_TEST_TIMEOUT}" \
  --keep-going \
  --require-suite \
  --junit-report=junit-kmm.xml \
  --json-report=ginkgo-kmm.json \
  --output-dir="${ARTIFACT_DIR}" \
  ./tests/hw-accel/kmm/modules/...
test_rc="$?"

oc get modules.kmm.sigs.x-k8s.io --all-namespaces \
  -o custom-columns='NAMESPACE:.metadata.namespace,STATE:.status.state,AVAILABLE:.status.conditions[?(@.type=="Available")].status' \
  > "${ARTIFACT_DIR}/kmm-modules.yaml" 2>&1 || true
oc get pods --namespace openshift-kmm \
  -o custom-columns='PHASE:.status.phase,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount' \
  > "${ARTIFACT_DIR}/kmm-pods.txt" 2>&1 || true
oc get events --namespace openshift-kmm --sort-by=.lastTimestamp \
  -o custom-columns='TYPE:.type,REASON:.reason,COUNT:.count,LAST:.lastTimestamp' \
  > "${ARTIFACT_DIR}/kmm-events.txt" 2>&1 || true
oc get csv --namespace openshift-kmm \
  -o custom-columns='PHASE:.status.phase,REASON:.status.reason,AVAILABLE:.status.conditions[?(@.type=="Available")].status' \
  > "${ARTIFACT_DIR}/kmm-csvs.yaml" 2>&1 || true

exit "${test_rc}"
