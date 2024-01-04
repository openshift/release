#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

if [ ! -f "${SHARED_DIR}/bastion_public_address" ] || [ ! -f "${SHARED_DIR}/bastion_ssh_user" ]; then
    echo "ERROR: Failed to get bastion host info, abort. " && exit 1
fi

function run_command() {
    local cmd="$1"
    echo "Running Command: ${cmd}"
    eval "${cmd}"
}

export KUBECONFIG=${SHARED_DIR}/kubeconfig

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

ssh_key_file_name="ssh-privatekey"
ssh_key=${CLUSTER_PROFILE_DIR}/${ssh_key_file_name}
bastion_dns=$(head -n 1 "${SHARED_DIR}/bastion_public_address")
bastion_user=$(head -n 1 "${SHARED_DIR}/bastion_ssh_user")

working_dir=$(mktemp -d)
pushd "${working_dir}"

ssh_proxy_cmd_template="ssh -i ${ssh_key} -o StrictHostKeyChecking=no -o ProxyCommand=\"ssh -i ${ssh_key} -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -W %h:%p ${bastion_user}@${bastion_dns}\" core@NODE_IP \"grep -cw vmx /proc/cpuinfo\" 1>stdout.log"

echo "INFO: Listing the cluster nodes..."
oc get nodes -o wide

failed=0
readarray -t nodes < <(oc get nodes -o wide --no-headers | awk '{print $1,$6}')
for name_and_ip in "${nodes[@]}"; do
    node_name="${name_and_ip% *}"
    node_ip="${name_and_ip#* }"
    echo "INFO: Processing node '${node_name}' (${node_ip})..."
    cmd=$(echo "${ssh_proxy_cmd_template}" | sed "s/NODE_IP/${node_ip}/")
    run_command "${cmd}" || failed=2
    n_vmx=$(head -n 1 stdout.log)
    echo "INFO: Found '${n_vmx}' occurrences of 'vmx' from '/proc/cpuinfo'."
    if [ -z ${n_vmx} ] || [ ${n_vmx} -eq 0 ]; then
        echo "ERROR: No nested virtualization on node '${node_name}'."
        failed=3
    fi
done

popd
rm -fr "${working_dir}"

if [ $failed -ne 0 ]; then
    echo "ERROR: Nested virtualization check failed."
else
    echo "INFO: Nested virtualization check passed."
fi
echo "INFO: exit code '$failed'"
exit $failed