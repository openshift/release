#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
ansible-playbook -i "${SHARED_DIR}/ansible-hosts" playbooks/scaleup.yml -vvv


export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Remove CoreOS machine sets
mapfile -t COREOS_MACHINE_SETS < <(oc get machinesets --namespace openshift-machine-api | grep worker | grep -v rhel | awk '{print $1}' || true)
if [[ ${#COREOS_MACHINE_SETS[@]} != 0 ]]
then
    oc delete machinesets --namespace openshift-machine-api "${COREOS_MACHINE_SETS[@]}"
fi

oc get nodes --output=wide
oc get machinesets --namespace openshift-machine-api
