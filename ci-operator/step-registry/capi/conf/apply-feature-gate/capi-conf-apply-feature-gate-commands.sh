#!/bin/bash
set -o nounset
set -o pipefail
set -e

export ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp}

export CAPI_NAMESPACE="openshift-cluster-api"
export CAPI_OPERATOR_NAMESPACE="openshift-cluster-api-operator"


# isOCPVersionLowerThan returns 0 if the current OCP version is lower than the required version, 1 otherwise
function isOCPVersionLowerThan() {
  local required_version="${1}"
  local version
  version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
  # If version sorted last, it means version >= required, so return 1 (not lower than)
  if [[ $(echo -e "${required_version}\n${version}" | sort -V | tail -n 1) == "${version}" ]]; then
    return 1
  else
    return 0
  fi
}
export -f isOCPVersionLowerThan

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

function waitForClusterOperatorsRollout() {
  echo "$(date -u --rfc-3339=seconds) - Wait for the operator to go available..."
  waitFor 10m oc wait --all --for=condition=Available=True clusteroperators.config.openshift.io

  echo "$(date -u --rfc-3339=seconds) - Waits for operators to finish rolling out..."
  waitFor 30m oc wait --all --for=condition=Progressing=False clusteroperators.config.openshift.io
}

function waitForRunningPod() {
  local NAMESPACE="${1}"
  local REGEXP="${2}"
  local MSG="${3}"

  while [ "$(oc get pods -n ${NAMESPACE} -o name | grep "${REGEXP}" | wc -l)" == 0 ]; do
    echo "$(date -u --rfc-3339=seconds) - ${MSG}"
    sleep 5
  done
}
export -f waitForRunningPod

function ClusterCAPIOperatorPodsCreated() {
  # OCP >= 4.22: new namespace/deployments structure (see: https://github.com/openshift/cluster-capi-operator/pull/447)
  if isOCPVersionLowerThan 4.22; then
    waitForRunningPod "${CAPI_NAMESPACE}" "cluster-capi-operator" "Waiting for cluster-capi-operator creation"
  else
    waitForRunningPod "${CAPI_OPERATOR_NAMESPACE}" "capi-operator" "Waiting for capi-operator creation"
    waitForRunningPod "${CAPI_NAMESPACE}" "capi-controllers" "Waiting for capi-controllers creation"
  fi

  waitForRunningPod "${CAPI_NAMESPACE}" "capi-controller-manager" "Waiting for capi-controller-manager creation"
}
export -f ClusterCAPIOperatorPodsCreated

function waitForClusterCAPIOperatorPodsReadiness() {
  # OCP >= 4.22: new namespace/deployments structure (see: https://github.com/openshift/cluster-capi-operator/pull/447)
  if ! isOCPVersionLowerThan 4.22; then
    echo "$(date -u --rfc-3339=seconds) - Wait for openshift-cluster-api-operator components to be ready"
    waitFor 10m oc wait --all -n "${CAPI_OPERATOR_NAMESPACE}" --for=condition=ready pods
  fi

  echo "$(date -u --rfc-3339=seconds) - Wait for openshift-cluster-api components to be ready"
  waitFor 10m oc wait --all -n "${CAPI_NAMESPACE}" --for=condition=ready pods
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
waitFor 30m ClusterCAPIOperatorPodsCreated
waitForClusterCAPIOperatorPodsReadiness
waitForClusterOperatorsRollout
