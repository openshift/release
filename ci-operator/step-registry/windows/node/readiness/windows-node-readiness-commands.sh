#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

expected_nodes="${WINDOWS_NODE_REPLICAS:-2}"
deadline_seconds=$((55 * 60))
start_seconds=${SECONDS}

while :; do
  windows_machinesets="$(
    oc get machinesets -n openshift-machine-api -o json |
      jq '[.items[] | select(.spec.template.metadata.labels["machine.openshift.io/os-id"] == "Windows") | {desired: (.spec.replicas // 0), ready: (.status.readyReplicas // 0)}]'
  )"

  total_machinesets="$(jq 'length' <<<"${windows_machinesets}")"
  if (( total_machinesets == 0 )); then
    echo "ERROR: No Windows MachineSets were found"
    exit 1
  fi

  ready_machinesets="$(
    jq '[.[] | select(.ready >= .desired)] | length' <<<"${windows_machinesets}"
  )"

  ready_nodes="$(
    oc get nodes -l kubernetes.io/os=windows -o json |
      jq '[.items[] | select((.status.conditions // []) | any(.type == "Ready" and .status == "True"))] | length'
  )"

  echo "Windows MachineSets ready: ${ready_machinesets}/${total_machinesets}; Windows nodes Ready: ${ready_nodes}/${expected_nodes}"

  if (( ready_machinesets == total_machinesets && ready_nodes >= expected_nodes )); then
    exit 0
  fi

  if (( SECONDS - start_seconds >= deadline_seconds )); then
    echo "ERROR: Timed out waiting for Windows readiness: MachineSets ${ready_machinesets}/${total_machinesets}, Ready nodes ${ready_nodes}/${expected_nodes}"
    exit 1
  fi

  sleep 10
done
