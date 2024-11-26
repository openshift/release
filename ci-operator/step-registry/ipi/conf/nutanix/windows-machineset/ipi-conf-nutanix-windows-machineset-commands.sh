#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Ensure necessary environment variables are set
export user_data_secret=${WINDOWS_USER_DATA_SECRET:?Environment variable WINDOWS_USER_DATA_SECRET must be set}
export windows_os_id=${WINDOWS_OS_ID:?Environment variable WINDOWS_OS_ID must be set}

# Wait for the Windows Machine Config Operator (WMCO) to start and reach an available state
oc wait deployment windows-machine-config-operator -n openshift-windows-machine-config-operator --for condition=Available=True --timeout=5m

# Ensure the userDataSecret exists, or fail
timeout 3m bash -c 'until oc -n openshift-machine-api get secret "${WINDOWS_USER_DATA_SECRET}" 2> /dev/null; do echo -n "." && sleep 15; done'

# Get the name of a reference Linux worker MachineSet to use as a template
# We now retrieve all MachineSets and filter using grep, as jsonpath does not support contains
ref_machineset_name=$(oc get machinesets -n openshift-machine-api -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep 'worker' | head -n1)
if [ -z "$ref_machineset_name" ]; then
  echo "Error: No worker MachineSet found."
  exit 1
fi

# Replace `worker` in the MachineSet name with `winworker`
winworker_machineset_name="winworker"

# Get the Nutanix cluster and subnet UUID
cluster_uuid=$(oc get machines.machine.openshift.io -o jsonpath='{.items[-1].spec.providerSpec.value.cluster.uuid}' -n openshift-machine-api)
subnet_uuid=$(oc get machines.machine.openshift.io -o jsonpath='{.items[-1].spec.providerSpec.value.subnets[0].uuid}' -n openshift-machine-api)

if [ -z "$cluster_uuid" ] || [ -z "$subnet_uuid" ]; then
  echo "Error: Could not retrieve cluster or subnet UUID."
  exit 1
fi

# Use jq for JSON replacement, ensuring proper JSON formatting
oc get machineset "${ref_machineset_name}" -n openshift-machine-api -o json | \
jq --arg name "$winworker_machineset_name" \
   --arg subnet_uuid "$subnet_uuid" \
   --arg windows_os_id "$windows_os_id" \
   --arg cluster_uuid "$cluster_uuid" \
   --arg user_data_secret "$user_data_secret" \
   '.metadata.name = $name |
    .metadata.labels["machine.openshift.io/os-id"] = "Windows" |
    .metadata.labels["machine.openshift.io/cluster-api-machine-role"] = "worker" |
    .metadata.labels["machine.openshift.io/cluster-api-machine-type"] = "worker" |
    .spec.replicas = 1 |  # You can increase the replica count here if needed
    .spec.template.metadata.labels["machine.openshift.io/os-id"] = "Windows" |
    .spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-role"] = "worker" |
    .spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-type"] = "worker" |
    .spec.template.metadata.labels["node-role.kubernetes.io/worker"] = "" |  
    .spec.template.spec.providerSpec.value.cluster.uuid = $cluster_uuid |
    .spec.template.spec.providerSpec.value.subnets[0].uuid = $subnet_uuid |
    .spec.template.spec.providerSpec.value.image.name = $windows_os_id |
    .spec.template.spec.providerSpec.value.os = {"id": "Windows"} |
    .spec.template.spec.providerSpec.value.userDataSecret.name = $user_data_secret |
    del(.spec.template.spec.providerSpec.value.image.uuid) | 
    del(.status, .metadata.selfLink, .metadata.uid)' | \
oc create -f -

# Scale machineset to expected number of replicas
oc -n openshift-machine-api scale machineset/"${winworker_machineset_name}" --replicas="${WINDOWS_NODE_REPLICAS}"
