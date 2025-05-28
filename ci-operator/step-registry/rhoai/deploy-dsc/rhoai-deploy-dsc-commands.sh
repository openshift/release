#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "Deploying a DataScience Cluster"
csv=$(oc get csv -n default -o json | jq -r '.items[] | select(.metadata.name | startswith("rhods-operator"))')
if [[ -z "${csv}" ]]; then
  echo "Error: Cannot find csv with name 'rhods-operator*'"
  oc get csv -n default
  exit 1
fi

csv_name=$(echo "${csv}" | jq -r '.metadata.name')
echo "Found csv '${csv_name}'"
echo "Found the initialization-resource"
echo "${csv}" | jq -r '.metadata.annotations."operatorframework.io/initialization-resource"' | jq -r | tee "/tmp/default-dsc.json"
file="/tmp/default-dsc.json"
oc apply -f "${file}"

echo "⏳ Wait for DataScientCluster to be deployed"
oc wait --for=jsonpath='{.status.phase}'=Ready datasciencecluster/${DSC_NAME} --timeout=9000s

# Verify all pods are running
oc_wait_for_pods() {
    local ns="${1}"
    local pods

    for _ in {1..60}; do
        echo "Waiting for pods in '${ns}' in state Running or Completed"
        pods=$(oc get pod -n "${ns}" | grep -v "Running\|Completed" | tail -n +2)
        echo "${pods}"
        if [[ -z "${pods}" ]]; then
            echo "All pods in '${ns}' are in state Running or Completed"
            break
        fi
        sleep 20
    done
    if [[ -n "${pods}" ]]; then
        echo "ERROR: Some pods in '${ns}' are not in state Running or Completed"
        echo "${pods}"
        exit 1
    fi
}
oc_wait_for_pods "redhat-ods-applications"

sleep 300
echo "OpenShfit AI Operator is deployed successfully"
