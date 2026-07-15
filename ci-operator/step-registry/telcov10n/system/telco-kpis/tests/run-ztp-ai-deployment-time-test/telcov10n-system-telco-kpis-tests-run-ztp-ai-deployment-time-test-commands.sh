#!/bin/bash
set -euo pipefail

# Prow runs containers with arbitrary UIDs and HOME=/ (not writable).
# Ansible resolves ~/.ansible/tmp via /etc/passwd, not $HOME, for delegate_to: localhost tasks.
export ANSIBLE_REMOTE_TMP=/tmp/.ansible/tmp

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

MOUNTED_HOST_INVENTORY="/var/host_variables"
MOUNTED_GROUP_INVENTORY="/var/group_variables"

setup_ssh_jump() {
    local mounted_host_inventory="$1"
    local mounted_group_inventory="$2"
    local bastion_host_vars="$3"

    echo "Configuring SSH jump through hypervisor to reach bastion..."

    local hypervisor_ip
    hypervisor_ip=$(tr -d '[:space:]' < "${mounted_host_inventory}/common/hypervisor/ansible_host")

    local ssh_user
    ssh_user=$(tr -d '[:space:]' < "${mounted_group_inventory}/common/all/ansible_user")

    local ssh_key_file="/tmp/ssh-jump-key"
    [[ $- == *x* ]] && local was_tracing=true || local was_tracing=false
    set +x
    cat "${mounted_group_inventory}/common/all/ansible_ssh_private_key" > "${ssh_key_file}"
    $was_tracing && set -x
    chmod 600 "${ssh_key_file}"

    python3 -c "
import yaml, sys

key = 'ansible_ssh_common_args'
ssh_key, user, host = sys.argv[1], sys.argv[2], sys.argv[3]
proxy = (
    '-o StrictHostKeyChecking=no '
    '-o UserKnownHostsFile=/dev/null '
    '-o ProxyCommand=\"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null '
    f'-i {ssh_key} -W %h:%p {user}@{host}\"'
)
print(yaml.dump({key: proxy}, default_flow_style=False, allow_unicode=True).rstrip())
" "${ssh_key_file}" "${ssh_user}" "${hypervisor_ip}" >> "${bastion_host_vars}"

    echo "SSH jump configured: container -> ${ssh_user}@${hypervisor_ip} -> bastion"
}

process_inventory() {
    local directory="$1"
    local dest_file="$2"

    if [ -z "$directory" ]; then
        echo "Usage: process_inventory <directory> <dest_file>"
        return 1
    fi

    if [ ! -d "$directory" ]; then
        echo "Error: '$directory' is not a valid directory"
        return 1
    fi

    # Clear/create destination file
    : > "${dest_file}"

    find "$directory" -type f | while IFS= read -r filename; do
        if [[ $filename == *"secretsync-vault-source-path"* ]]; then
          continue
        fi

        key=$(basename "${filename}")
        # Use Python to safely serialize YAML with proper escaping for multi-line values and quotes
        python3 -c "
import yaml
import sys

key = sys.argv[1]
with open(sys.argv[2], 'r') as f:
    value = f.read()

# Output as YAML - handles multi-line and quotes correctly
print(yaml.dump({key: value}, default_flow_style=False, allow_unicode=True).rstrip())
" "$key" "$filename" >> "${dest_file}"
    done

    echo "Processing complete. Check \"${dest_file}\""
}

main() {
    echo "Collecting node information for spoke: ${SPOKE_CLUSTER}"

    echo "Create group_vars directory"
    mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

    # Process common group variables
    find "${MOUNTED_GROUP_INVENTORY}/common/" -mindepth 1 -type d | while read -r dir; do
        echo "Process common group inventory file: ${dir}"
        process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
    done

    # Process spoke-specific group variables
    if [[ -d "${MOUNTED_GROUP_INVENTORY}/${SPOKE_CLUSTER}" ]]; then
        find "${MOUNTED_GROUP_INVENTORY}/${SPOKE_CLUSTER}/" -mindepth 1 -type d | while read -r dir; do
            echo "Process spoke group inventory file: ${dir}"
            process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
        done
    fi

    echo "Create host_vars directory"
    mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

    # Copy spoke credentials to temporary location
    mkdir -p /tmp/"${SPOKE_CLUSTER}" && chmod 700 /tmp/"${SPOKE_CLUSTER}"

    # Copy common hypervisor credentials (shared across all spokes)
    if [[ -d "${MOUNTED_HOST_INVENTORY}/common/hypervisor" ]]; then
        cp -r "${MOUNTED_HOST_INVENTORY}/common/hypervisor" /tmp/"${SPOKE_CLUSTER}"/hypervisor
    fi
    if [[ -d "${MOUNTED_HOST_INVENTORY}/${SPOKE_CLUSTER}" ]]; then
        cp -r "${MOUNTED_HOST_INVENTORY}/${SPOKE_CLUSTER}/"* /tmp/"${SPOKE_CLUSTER}"/
    fi
    ls -l /tmp/"${SPOKE_CLUSTER}"/

    # Process spoke host variables
    find /tmp/"${SPOKE_CLUSTER}"/ -mindepth 1 -type d | while read -r dir; do
        echo "Process spoke host inventory file: ${dir}"
        process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/host_vars/"$(basename "${dir}")"
    done

    # Process hub bastion credentials (for accessing hub cluster)
    if [[ -d "${MOUNTED_HOST_INVENTORY}/${HUB_CLUSTER}/bastion" ]]; then
        echo "Process hub bastion inventory file: ${MOUNTED_HOST_INVENTORY}/${HUB_CLUSTER}/bastion"
        process_inventory "${MOUNTED_HOST_INVENTORY}/${HUB_CLUSTER}/bastion" /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion
    fi

    # Configure SSH jump: Prow container -> hypervisor (hv6) -> bastion
    setup_ssh_jump "${MOUNTED_HOST_INVENTORY}" "${MOUNTED_GROUP_INVENTORY}" \
        /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion

    # Kubeconfig paths on the bastion (not in SHARED_DIR — Ansible SSHes to bastion)
    HUB_KUBECONFIG="/home/telcov10n/project/generated/${HUB_CLUSTER}/auth/kubeconfig"
    SPOKE_KUBECONFIG="/tmp/${SPOKE_CLUSTER}-kubeconfig"

    echo "Using kubeconfig paths on bastion:"
    echo "  Hub kubeconfig: ${HUB_KUBECONFIG}"
    echo "  Spoke kubeconfig: ${SPOKE_KUBECONFIG}"

    cd /eco-ci-cd

    echo "Running collect-node-info playbook for spoke ${SPOKE_CLUSTER}"
    DEBUG_FLAG=""
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi
    ansible-playbook ./playbooks/telco-kpis/collect-node-info.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e spoke_cluster="${SPOKE_CLUSTER}" \
        -e spoke_kubeconfig="${SPOKE_KUBECONFIG}" \
        -e skip_rebuild_image="${SKIP_REBUILD_IMAGE}" \
        ${DEBUG_FLAG}

    echo "Copy artifacts to ARTIFACT_DIR and SHARED_DIR"
    mkdir -p "${ARTIFACT_DIR}/telco-kpis"
    if [[ -f "/tmp/node-info-${SPOKE_CLUSTER}.json" ]]; then
        cp "/tmp/node-info-${SPOKE_CLUSTER}.json" "${ARTIFACT_DIR}/telco-kpis/"
        cp "/tmp/node-info-${SPOKE_CLUSTER}.json" "${SHARED_DIR}/"
    else
        echo "WARNING: node-info file not found at /tmp/node-info-${SPOKE_CLUSTER}.json"
    fi

    echo "Node information collection completed for ${SPOKE_CLUSTER}"
}

main
