#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Start Running Case https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-51169"

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

sleep 3600

oc get node -l node-role.kubernetes.io/worker= --no-headers | wc -l

SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

# Check MachineConfig have kerneltype applied
if oc get machineconfigs | grep "99-master-kerneltype"; then
    echo "Pass: check 99-master-kerneltype set"
else
    echo "Fail: check 99-master-kerneltype set"
    exit 1
fi
if oc get machineconfigs | grep "99-worker-kerneltype"; then
    echo "Pass: check 99-worker-kerneltype set"
else
    echo "Fail: check 99-worker-kerneltype set"
    exit 1
fi

IFS=' ' read -r -a node_ips <<<"$(oc get machines -n openshift-machine-api -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')"

# Check all nodes have RT kernel running
for node_ip in "${node_ips[@]}"; do
    uname="$(ssh -o "StrictHostKeyChecking no" -i "${SSH_PRIV_KEY_PATH}" core@"$node_ip" uname -r)"
    if echo "$uname" | grep "rt"; then
        echo "Pass: check node: $node_ip have RT kernel running"
    else
        echo "Fail: check node: $node_ip have RT kernel running"
        exit 1
    fi
done

# Restore
