#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Start Running Case https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-46245"

sleep 3600


# sh-4.4$ govc vm.info -json ci-op-1gql3glg-32a2e-9gkf9-master-2 | grep -i thin
#                 "ThinProvisioned": true,

# govc vm.info -json ci-op-1gql3glg-32a2e-9gkf9-master-2 | jq -r .VirtualMachines[].Layout.Disk[].DiskFile[]

# sh-4.4$ govc vm.info -json ci-op-1gql3glg-32a2e-9gkf9-master-2 | jq -r .VirtualMachines[].Layout.Disk[].DiskFile[]
# govc: mkdir /output/.govmomi: permission denied
# sh-4.4$ export  HOME=/tmp
# sh-4.4$ govc vm.info -json ci-op-1gql3glg-32a2e-9gkf9-master-2 | jq -r .VirtualMachines[].Layout.Disk[].DiskFile[]
# [vsanDatastore] e21c2665-da32-a56b-9303-3cecef1c81aa/ci-op-1gql3glg-32a2e-9gkf9-master-2.vmdk
# sh-4.4$ govc datastore.disk.info ci-op-1gql3glg-32a2e-9gkf9-master-2.vmdk
# govc: File [vsanDatastore] ci-op-1gql3glg-32a2e-9gkf9-master-2.vmdk was not found
# sh-4.4$ govc datastore.disk.info e21c2665-da32-a56b-9303-3cecef1c81aa/ci-op-1gql3glg-32a2e-9gkf9-master-2.vmdk
# Name:      e21c2665-da32-a56b-9303-3cecef1c81aa/ci-op-1gql3glg-32a2e-9gkf9-master-2.vmdk
#   Type:    thin
#   Parent:

# Hardware

# Check all virtual machines of cluster are thin
if [ "$(oc get node -l node-role.kubernetes.io/worker= --no-headers | wc -l)" != "2" ]; then
    echo "Fail: check worker number"
    exit 1
fi

# Check each node has customized physical resources as install_config
IFS=' ' read -r -a node_names <<< "$(oc get machines -n openshift-machine-api -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalDNS")].address}')"
for node_name in "${node_names[@]}"; do
    if [ "$(oc get machine "$node_name" -n openshift-machine-api -o jsonpath='{.spec.providerSpec.value.numCPUs}')" != "4" ]; then
        echo "Fail: check $node_name numCPUs"
        exit 1
    fi
    if [ "$(oc get machine "$node_name" -n openshift-machine-api -o jsonpath='{.spec.providerSpec.value.numCoresPerSocket}')" != "2" ]; then
        echo "Fail: check $node_name numCoresPerSocket"
        exit 1
    fi
    if [ "$(oc get machine "$node_name" -n openshift-machine-api -o jsonpath='{.spec.providerSpec.value.memoryMiB}')" != "20000" ]; then
        echo "Fail: check $node_name memoryMiB"
        exit 1
    fi
    if [ "$(oc get machine "$node_name" -n openshift-machine-api -o jsonpath='{.spec.providerSpec.value.diskGiB}')" != "100" ]; then
        echo "Fail: check $node_name diskGiB"
        exit 1
    fi
done

# Check nutanix platform parameters are configured correctly in the machineset
oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.numCPUs}'
if [ "$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.numCPUs}')" != "4" ]; then
    echo "Fail: check $node_name numCPUs"
    exit 1
fi
if [ "$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.numCoresPerSocket}')" != "4" ]; then
    echo "Fail: check $node_name numCoresPerSocket"
    exit 1
fi
if [ "$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.memoryMiB}')" != "4" ]; then
    echo "Fail: check $node_name memoryMiB"
    exit 1
fi
if [ "$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.diskGiB}')" != "4" ]; then
    echo "Fail: check $node_name diskGiB"
    exit 1
fi

# Restore
