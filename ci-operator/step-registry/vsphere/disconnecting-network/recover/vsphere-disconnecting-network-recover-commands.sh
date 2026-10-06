#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

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

SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
BASTION_IP=$(<"${SHARED_DIR}/bastion_private_address")
BASTION_SSH_USER=$(<"${SHARED_DIR}/bastion_ssh_user")

function check_latest_machineconfig_applied() {
    local role="$1" cmd latest_machineconfig applied_machineconfig_machines ready_machines

    cmd="oc get machineconfig"
    echo "Command: $cmd"
    eval "$cmd"

    echo "Checking $role machines are applied with latest $role machineconfig..."
    latest_machineconfig=$(oc get machineconfig --sort-by='{.metadata.creationTimestamp}' | grep "rendered-${role}-" | tail -1 | awk '{print $1}')
    if [[ ${latest_machineconfig} == "" ]]; then
        echo >&2 "Did not found ${role} render machineconfig"
        return 1
    else
        echo "latest ${role} machineconfig: ${latest_machineconfig}"
    fi

    applied_machineconfig_machines=$(oc get node -l "node-role.kubernetes.io/${role}" -o json | jq -r --arg mc_name "${latest_machineconfig}" '.items[] | select(.metadata.annotations."machineconfiguration.openshift.io/state" == "Done" and .metadata.annotations."machineconfiguration.openshift.io/currentConfig" == $mc_name) | .metadata.name' | sort)
    ready_machines=$(oc get node -l "node-role.kubernetes.io/${role}" -o json | jq -r '.items[].metadata.name' | sort)
    if [[ ${applied_machineconfig_machines} == "${ready_machines}" ]]; then
        echo "latest machineconfig - ${latest_machineconfig} is already applied to ${ready_machines}"
        return 0
    else
        echo "latest machineconfig - ${latest_machineconfig} is applied to ${applied_machineconfig_machines}, but expected ready node lists: ${ready_machines}"
        return 1
    fi
}

function wait_machineconfig_applied() {
    local role="${1}" try=0 interval=60
    num=$(oc get node --no-headers -l node-role.kubernetes.io/"$role"= | wc -l)
    local max_retries; max_retries=$((num*10))
    while (( try < max_retries )); do
        echo "Checking #${try}"
        if ! check_latest_machineconfig_applied "${role}"; then
            sleep ${interval}
        else
            break
        fi
        (( try += 1 ))
    done
    if (( try == max_retries )); then
        echo >&2 "Timeout waiting for all $role machineconfigs are applied"
        return 1
    else
        echo "All ${role} machineconfigs check PASSED"
        return 0
    fi
}

#Recover network
echo "Recovering network"
ssh -o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no "${BASTION_SSH_USER}"@"${BASTION_IP}" \
    "sudo rm -rf /etc/dnsmasq.d/disconnected-dns.conf | sudo systemctl restart dnsmasq.service"

#Delete all created ICSP
echo "Deleting all created ICSP"
icsp_list=$(oc get imagecontentsourcepolicy --no-headers | awk '{print $1}')
oc delete imagecontentsourcepolicy "${icsp_list}"
echo "Make sure all machines are applied with latest machineconfig"
wait_machineconfig_applied "master"
wait_machineconfig_applied "worker"
