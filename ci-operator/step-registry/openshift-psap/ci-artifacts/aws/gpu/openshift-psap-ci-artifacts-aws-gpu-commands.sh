#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, can not continue."
	exit 0
fi

# Desired GPU instance type
# Choose one from https://docs.aws.amazon.com/dlami/latest/devguide/gpu.html
instance_type=g4dn.xlarge
# Get machineset name to generate a generic template
ref_machineset_name=$(oc get machinesets -n openshift-machine-api |grep worker |awk 'NR==1{print $1}')

# Get machineset temaplte
template_machineset=$(oc get machineset $ref_machineset_name -n openshift-machine-api -o json) 

# Replace machine name worker to gpu
gpu_machineset_name=$(echo ${template_machineset} |jq -c '.metadata.name' |sed -e 's/worker/gpu/' |sed -e 's/^"//' -e 's/"$//')

export instance_type ref_machineset_name gpu_machineset_name
# Get a templated json from a running machine, change machine type and machine name
# and pass it to oc to create a new machine set
set +o errexit
oc get -nopenshift-machine-api machineset $ref_machineset_name -o json \
    | jq --arg instance_type "${instance_type}" '.spec.template.spec.providerSpec.value.instanceType = $instance_type' \
    | jq --arg gpu_machineset_name "${gpu_machineset_name}" '.metadata.name = $gpu_machineset_name' \
    | jq --arg gpu_machineset_name "${gpu_machineset_name}" '.spec.template.metadata.labels."machine.openshift.io/cluster-api-machineset" = $gpu_machineset_name' \
    | jq --arg gpu_machineset_name "${gpu_machineset_name}" '.spec.selector.matchLabels."machine.openshift.io/cluster-api-machineset" = $gpu_machineset_name' \
    | jq 'del(.status)|del(.metadata.selfLink)|del(.metadata.uid)' \
    | oc create -f -
set -o errexit

# Wait until the new node is provisioned by the control plane
set +o errexit
gpu_machine_state=$(oc get machines -n openshift-machine-api |grep $instance_type |awk '{ print $2 }')
while [ "${gpu_machine_state}" != "Running" ]; do
  sleep 5s
  gpu_machine_state=$(oc get machines -n openshift-machine-api |grep "$instance_type" |awk '{ print $2 }')
done
set -o errexit
set +x
