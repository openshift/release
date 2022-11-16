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

oc version --client

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    echo "Setting proxy"
    source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "$(date -u --rfc-3339=seconds) - Validating parsed Ansible inventory"
ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml
echo "$(date -u --rfc-3339=seconds) - Running RHEL worker scaleup"
ansible-playbook -i "${SHARED_DIR}/ansible-hosts" playbooks/scaleup.yml -vvv


if [[ "${REMOVE_RHCOS_WORKER}" == "no" ]]; then
    echo "RHCOS worker will not be removed!"
    exit 0
fi

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Remove CoreOS machine sets
echo "$(date -u --rfc-3339=seconds) - Deleting CoreOS machinesets"
mapfile -t COREOS_MACHINE_SETS < <(oc get machinesets --namespace openshift-machine-api | grep worker | grep -v rhel | awk '{print $1}' || true)
if [[ ${#COREOS_MACHINE_SETS[@]} != 0 ]]
then
    oc delete machinesets --namespace openshift-machine-api "${COREOS_MACHINE_SETS[@]}"
fi

echo "$(date -u --rfc-3339=seconds) - Waiting for CoreOS nodes to be removed"
oc wait node \
    --for=delete \
    --timeout=10m \
    --selector node.openshift.io/os_id=rhcos,node-role.kubernetes.io/worker \
    || true

echo "$(date -u --rfc-3339=seconds) - Waiting for worker machineconfigpool to update"
oc wait machineconfigpool/worker \
    --for=condition=Updated=True \
    --timeout=10m

echo "$(date -u --rfc-3339=seconds) - Waiting for clusteroperators to complete"
oc wait clusteroperator.config.openshift.io \
    --for=condition=Available=True \
    --for=condition=Progressing=False \
    --for=condition=Degraded=False \
    --timeout=20m \
    --all

echo "$(date -u --rfc-3339=seconds) - RHEL worker scaleup complete"
