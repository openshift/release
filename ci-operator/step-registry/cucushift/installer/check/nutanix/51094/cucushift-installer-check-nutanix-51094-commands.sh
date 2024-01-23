#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Start Running Case https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-51169"

# Check 2 worker nodes are joined in without error
if [ "$(oc get node -l node-role.kubernetes.io/worker= --no-headers | wc -l)" != "2" ]; then
    echo "Fail: check worker number"
    exit 1
fi

# Check each node has customized physical resources as install_config
IFS=' ' read -r -a node_names <<< "$(oc get machines -n openshift-machine-api -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalDNS")].address}')"
for node_name in "${node_names[@]}"; do
    if [ "$(oc get machine "$node_name" -n openshift-machine-api -o jsonpath='{.spec.providerSpec.value.vcpuSockets}')" != "4" ]; then
        echo "Fail: check $node_name vcpuSockets"
        exit 1
    fi
    if [ "$(oc get machine "$node_name" -n openshift-machine-api -o jsonpath='{.spec.providerSpec.value.vcpusPerSocket}')" != "2" ]; then
        echo "Fail: check $node_name vcpusPerSocket"
        exit 1
    fi

    if [ "$(oc get machine "$node_name" -n openshift-machine-api -o jsonpath='{.spec.providerSpec.value.memorySize}')" != "20000Mi" ]; then
        echo "Fail: check $node_name memorySize"
        exit 1
    fi
    if [ "$(oc get machine "$node_name" -n openshift-machine-api -o jsonpath='{.spec.providerSpec.value.systemDiskSize}')" != "100Gi" ]; then
        echo "Fail: check $node_name systemDiskSize"
        exit 1
    fi
done

# Check nutanix platform parameters are configured correctly in the machineset
if [ "$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.vcpuSockets}')" != "4" ]; then
    echo "Fail: check $node_name vcpuSockets"
    exit 1
fi
if [ "$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.vcpusPerSocket}')" != "2" ]; then
    echo "Fail: check $node_name vcpusPerSocket"
    exit 1
fi
if [ "$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.memorySize}')" != "20000Mi" ]; then
    echo "Fail: check $node_name memorySize"
    exit 1
fi
if [ "$(oc get machineset -n openshift-machine-api -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.systemDiskSize}')" != "100Gi" ]; then
    echo "Fail: check $node_name systemDiskSize"
    exit 1
fi

# Restore
