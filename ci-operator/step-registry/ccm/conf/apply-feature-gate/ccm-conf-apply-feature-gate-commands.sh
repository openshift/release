#!/bin/bash
set -o nounset
set -o pipefail
set -e

export ARTIFACT_DIR=${ARTIFACT_DIR:-/tmp}

export CCM_NAMESPACE="openshift-cloud-controller-manager"

function applyFeatureGate() {
  echo "$(date -u --rfc-3339=seconds) - Apply external cloud-controller-manager FeatureGate configuration"

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

function waitForKubeletAndKCMRollout() {
  echo "$(date -u --rfc-3339=seconds) - Updated machineconfig should contain --cloud-provider=external flag..."
  waitFor 30m setExternalFlagMCO

  echo "$(date -u --rfc-3339=seconds) - Updated kube-controller-manager pods should contain --cloud-provider=external flag..."
  waitFor 30m setExternalFlagKCMO

  echo "$(date -u --rfc-3339=seconds) - All machineconfigs should be updated after rollout..."
  waitFor 30m oc wait --all --for=condition=Updated=True machineconfigpool

  echo "$(date -u --rfc-3339=seconds) - Wait for the operator to go available..."
  waitFor 10m oc wait --all --for=condition=Available=True clusteroperators.config.openshift.io

  echo "$(date -u --rfc-3339=seconds) - Waits for operators to finish rolling out..."
  waitFor 30m oc wait --all --for=condition=Progressing=False clusteroperators.config.openshift.io
}

function CCMPodsCreated() {
  while [ "$(oc get pods -n ${CCM_NAMESPACE} -o name | wc -l)" == 0 ]; do
    echo "$(date -u --rfc-3339=seconds) - Wait for CCCMO operands creation"
    sleep 5
  done
}
export -f CCMPodsCreated

function setExternalFlagMCO() {
  while [ "$(oc get machineconfig -o yaml | grep 'cloud-provider=external' | wc -l)" == 0 ]; do
    echo "$(date -u --rfc-3339=seconds) - Wait for machineconfig to set external cloud providers..."
    sleep 20
  done
}
export -f setExternalFlagMCO

function setExternalFlagKCMO() {
  KCM_NAMESPACE="openshift-kube-controller-manager"
 
  kcmPodsCount="$(oc get pods -n $KCM_NAMESPACE -l 'kube-controller-manager=true' -o name | wc -l)"
  while [ "$(oc get pods -n $KCM_NAMESPACE -o yaml | grep 'cloud-provider=external' | wc -l)" != "${kcmPodsCount}" ]; do
    echo "$(date -u --rfc-3339=seconds) - Waiting for kube-controller-manager to set external cloud providers..."
    sleep 20
  done
}
export -f setExternalFlagKCMO

function waitForCCMPodsReadiness() {
  echo "$(date -u --rfc-3339=seconds) - Wait for CCCMO operands to be ready"
  waitFor 3m oc wait --all -n "${CCM_NAMESPACE}" --for=condition=ready pods
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
waitFor 20m CCMPodsCreated
waitForCCMPodsReadiness
waitForKubeletAndKCMRollout
