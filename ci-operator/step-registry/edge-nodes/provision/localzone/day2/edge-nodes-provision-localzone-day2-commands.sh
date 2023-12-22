#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


export KUBECONFIG="${SHARED_DIR}/kubeconfig"

localzone_machineset=${SHARED_DIR}/manifest_localzone_machineset.yaml

function print_debug_info()
{
    echo "machineset info:"
    oc get machineset -n openshift-machine-api
    echo "machine info:"
    oc get machine -n openshift-machine-api -o wide
    echo "node info:"
    oc get node -o wide
}

trap 'print_debug_info' EXIT TERM INT

# update PLACEHOLDER_INFRA_ID and PLACEHOLDER_AMI_ID
name=$(oc get machineset -n openshift-machine-api  --no-headers | grep "\-worker\-" | awk '{print $1}' | head -n 1)
ami_id=$(oc get machineset -n openshift-machine-api $name -o "jsonpath={.spec.template.spec.providerSpec.value.ami.id}")
infra_id=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)

sed -i "s/PLACEHOLDER_INFRA_ID/$infra_id/g" ${localzone_machineset}
sed -i "s/PLACEHOLDER_AMI_ID/$ami_id/g" ${localzone_machineset}

echo "Creating Edge node:"
cat ${localzone_machineset}

oc create -f ${localzone_machineset}

echo "Waiting for new nodes get ready"
machineset_name=$(yq-go r ${localzone_machineset} 'metadata.name')
count=$(yq-go r ${localzone_machineset} 'spec.replicas')

echo "machineset_name: ${machineset_name}, expect count: ${count}"

try=1
total=50
interval=60
t=$(mktemp)
while [[ ${try} -le ${total} ]]; do
    echo "$(date) Checking new machine pool status (try ${try} / ${total})"
    oc get machineset -n openshift-machine-api ${machineset_name} --no-headers | tee ${t}
    if ! grep -E "(${count} +){4}" ${t} ; then
        echo "Not ready, waiting ${interval}s"
        sleep ${interval}
        (( try++ ))
        continue
    else
        echo "Machineset is ready."
        exit 0
    fi
done

exit 1