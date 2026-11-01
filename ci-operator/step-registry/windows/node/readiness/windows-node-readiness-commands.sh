#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

expected_nodes="${WINDOWS_NODE_REPLICAS:-2}"

windows_machinesets="$(
  oc get machinesets -n openshift-machine-api -o json |
    jq -r '.items[] | select(.spec.template.metadata.labels["machine.openshift.io/os-id"] == "Windows") | .metadata.name'
)"

if [[ -z "${windows_machinesets}" ]]; then
  echo "ERROR: No Windows MachineSets were found"
  oc get machinesets -n openshift-machine-api -o wide
  exit 1
fi

while IFS= read -r machineset; do
  desired_replicas="$(
    oc get machineset "${machineset}" -n openshift-machine-api -o jsonpath='{.spec.replicas}'
  )"
  echo "Waiting for MachineSet ${machineset} to have ${desired_replicas} ready replicas"
  oc wait "machineset/${machineset}" -n openshift-machine-api \
    --for="jsonpath={.status.readyReplicas}=${desired_replicas}" \
    --timeout=30m
done <<< "${windows_machinesets}"

echo "Waiting for ${expected_nodes} Windows nodes to become Ready"
oc wait nodes -l kubernetes.io/os=windows --for condition=Ready=True --timeout=30m

ready_nodes="$(
  oc get nodes -l kubernetes.io/os=windows --no-headers |
    awk '$2 == "Ready" || $2 ~ /^Ready,/ { count++ } END { print count + 0 }'
)"

if (( ready_nodes < expected_nodes )); then
  echo "ERROR: Expected ${expected_nodes} Ready Windows nodes, found ${ready_nodes}"
  oc get nodes -l kubernetes.io/os=windows -o wide
  exit 1
fi

echo "Found ${ready_nodes}/${expected_nodes} Ready Windows nodes"
oc get nodes -l kubernetes.io/os=windows -o wide
