#!/bin/bash
set -o nounset
set -o pipefail
set -e

export ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp}

export CAPI_NAMESPACE="openshift-cluster-api"

function applyFeatureGate() {
  echo "$(date -u --rfc-3339=seconds) - Apply TechPreviewNoUpgrade FeatureGate configuration"

  cat <<EOF | oc apply -f -
---
apiVersion: config.openshift.io/v1
kind: FeatureGate
metadata:
  annotations:
    include.release.openshift.io/self-managed-high-availability: "true"
    include.release.openshift.io/single-node-developer: "true"
    release.openshift.io/create-only: "true"
  name: cluster
spec:
  featureSet: TechPreviewNoUpgrade
EOF
}

function ClusterCAPIOperatorPodsCreated() {
  while [ "$(oc get pods -n ${CAPI_NAMESPACE} -o name | wc -l)" == 0 ]; do
    echo "$(date -u --rfc-3339=seconds) - Wait for CAPI operands creation"
    sleep 5
  done
}
export -f ClusterCAPIOperatorPodsCreated

function waitForClusterCAPIOperatorPodsReadiness() {
  echo "$(date -u --rfc-3339=seconds) - Wait for CAPI operands to be ready"
  waitFor 3m oc wait --all -n "${CAPI_NAMESPACE}" --for=condition=ready pods
}

function waitFor() {
  local TIMEOUT="${1}"
  local CMD="${*:2}"

  ret=0
  timeout "${TIMEOUT}" bash -c "execute ${CMD}" || ret="$?"

  # Command timed out
  if [[ ret -eq 124 ]]; then
    echo "$(date -u --rfc-3339=seconds) - Timed out waiting for result of $CMD"
    exit 1
  fi
}

function execute() {
  local CMD="${*}"

  # API server occasionally becomes unavailable, so we repeat command in case of error
  while true; do
    ret=0
    ${CMD} || ret="$?"

    if [[ ret -eq 0 ]]; then
      return
    fi

    echo "$(date -u --rfc-3339=seconds) - Command returned error $ret, retrying..."
  done
}
export -f execute


applyFeatureGate
waitFor 20m ClusterCAPIOperatorPodsCreated
waitForClusterCAPIOperatorPodsReadiness

