#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -f "${SHARED_DIR}/kubeconfig" ]] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

# Setup proxy if it's present in the shared dir
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]
then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

master_nodes=$(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
worker_nodes=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

first_node=$(echo ${master_nodes} | cut -d" " -f1)
cluster_name=$(<"${SHARED_DIR}"/clustername.txt)
vm_path="/${GOVC_DATACENTER}/vm/${cluster_name}"

current_hw_version=$(govc vm.info -json=true ${vm_path}/${first_node} | jq -r .VirtualMachines[0].Config.Version)
echo "Current hardware version is: ${current_hw_version}"
hw_version=$(echo ${current_hw_version} | cut -d'-' -f2)

if (( hw_version >= VSPHERE_HW_VERSION )); then
    echo "VM hardware version is not less than ${VSPHERE_HW_VERSION}, no upgrade is required"
    exit 0
fi

echo "Updating VM hardware version to ${VSPHERE_HW_VERSION}"
# shellcheck disable=SC2068
for node in ${master_nodes[@]} ${worker_nodes[@]}; do
    echo "Marking the node as unschedulable"
    oc adm cordon ${node}
    if [[ "${worker_nodes[*]}" =~ ${node} ]]; then
        echo "Evacuate the pods from the compute node"
        oc adm drain ${node} --force=true --delete-emptydir-data --ignore-daemonsets
    fi
    echo "Power off VM"
    govc vm.power -s=true ${vm_path}/${node}

    echo "Check VM is powered off"
    timeout=10
    while (( timeout > 0 )); do
        sleep 1m
        (( timeout -= 1))
        status=$(govc vm.info -json ${vm_path}/${node} | jq -r .VirtualMachines[].Runtime.PowerState)

        if [[ "${status}" == "poweredOff" ]]; then
            break
        fi
    done

    if [[ "${status}" != "poweredOff" ]]; then
        echo >&2 "Shutdown VM failed"
        oc describe node/${node}
        exit 1
    fi

    echo "Upgrade VM hardware version"
    govc vm.upgrade -vm ${vm_path}/${node} -version=${VSPHERE_HW_VERSION}

    echo "Check VM hardware version"
    post_hw_version=$(govc vm.info -json ${vm_path}/${node} | jq -r .VirtualMachines[].Config.Version)
    echo "Post VM hardware version: ${post_hw_version}"
    if [[ ! ${post_hw_version} =~ ${VSPHERE_HW_VERSION} ]]; then
        echo >&2 "VM hardware upgrade failed"
        oc describe node/${node}
        exit 1
    fi

    echo "Power on VM"
    govc vm.power -on=true ${vm_path}/${node}

    echo "Check VM status"
    timeout=10
    while (( timeout > 0 )); do
        sleep 1m
        (( timeout -= 1))
        status=$(govc vm.info -json ${vm_path}/${node} | jq -r .VirtualMachines[].Runtime.PowerState)

        if [[ "${status}" == "poweredOn" ]]; then
            break
        fi
    done

    if [[ "${status}" != "poweredOn" ]]; then
        echo >&2 "Poweron VM failed"
        oc describe node/${node}
        exit 1
    fi

    echo "Check node satus, should be Ready"
    res=$(oc wait --for=condition=Ready node/${node} --timeout=600s)
    if [[ ! ${res} =~ "condition met" ]]; then
        echo >&2 "Node is not ready with error: ${res}"
        oc describe node/${node}
        exit 1
    fi

    echo "Marking the node as schedulable again"
    oc adm uncordon ${node}

    echo "waiting for all co becomes Available"
    timeout=10
    while (( timeout > 0 )); do
        sleep 1m
        (( timeout -= 1))
        res=$(oc get co --no-headers| awk '{print $3$4$5}' | grep -vc 'TrueFalseFalse')

        if (( res == 0 )); then
            break
        fi
    done

    if (( res != 0 )); then
        echo >&2 "Not all co becomes Available, errors: ${res}"
        oc describe node/${node}
        exit 1
    fi
done
