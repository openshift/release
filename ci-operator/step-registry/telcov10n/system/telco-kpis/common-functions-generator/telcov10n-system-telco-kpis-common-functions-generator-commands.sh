#!/bin/bash
set -euo pipefail

echo "Generating telco-kpis shared functions..."

cat << 'EOF' > "${SHARED_DIR}/telco-kpis-common-functions.sh"
########################################################################
# Telco-KPIs shared functions for Prow steps
########################################################################

# Prow runs containers with arbitrary UIDs and HOME=/ (not writable).
# Ansible resolves ~/.ansible/tmp via /etc/passwd, not $HOME, for delegate_to: localhost tasks.
export ANSIBLE_REMOTE_TMP=/tmp/.ansible/tmp

MOUNTED_HOST_INVENTORY="/var/host_variables"
MOUNTED_GROUP_INVENTORY="/var/group_variables"

# ----------------------------------------------------------------------
# setup_ssh_jump
#
# Configures SSH ProxyCommand through the hypervisor (hv6) to reach
# the bastion. Appends ansible_ssh_common_args to the bastion host_vars
# so Ansible tunnels SSH transparently.
#
# Parameters:
#   1 - mounted_host_inventory: path to host variables mount
#   2 - mounted_group_inventory: path to group variables mount
#   3 - bastion_host_vars: path to bastion host_vars file to append to
# ----------------------------------------------------------------------

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

# ----------------------------------------------------------------------
# process_inventory
#
# Reads Kubernetes secret mount files from a directory and serializes
# each as a YAML key-value pair into a destination file, using Python
# yaml.dump for correct escaping of multi-line values and quotes.
#
# Parameters:
#   1 - directory: source directory containing secret mount files
#   2 - dest_file: destination file to write YAML key-value pairs
# ----------------------------------------------------------------------

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

    : > "${dest_file}"

    find "$directory" -type f | while IFS= read -r filename; do
        if [[ $filename == *"secretsync-vault-source-path"* ]]; then
          continue
        fi

        key=$(basename "${filename}")
        python3 -c "
import yaml
import sys

key = sys.argv[1]
with open(sys.argv[2], 'r') as f:
    value = f.read()

print(yaml.dump({key: value}, default_flow_style=False, allow_unicode=True).rstrip())
" "$key" "$filename" >> "${dest_file}"
    done

    echo "Processing complete. Check \"${dest_file}\""
}

# ----------------------------------------------------------------------
# setup_ansible_inventory
#
# Sets up the complete Ansible inventory from Kubernetes secret mounts:
#   1. Creates group_vars from common and spoke-specific group variables
#   2. Creates host_vars from hypervisor, spoke, and hub bastion credentials
#   3. Configures SSH jump through hypervisor to reach bastion
#
# Parameters:
#   1 - spoke_cluster: spoke cluster name (e.g., spree-02)
#   2 - hub_cluster: hub cluster name (e.g., kni-qe-71)
# ----------------------------------------------------------------------

setup_ansible_inventory() {
    local spoke_cluster="$1"
    local hub_cluster="$2"

    echo "Setting up Ansible inventory for spoke: ${spoke_cluster}, hub: ${hub_cluster}"

    echo "Create group_vars directory"
    mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars

    # Process common group variables
    find "${MOUNTED_GROUP_INVENTORY}/common/" -mindepth 1 -type d | while read -r dir; do
        echo "Process common group inventory file: ${dir}"
        process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
    done

    # Process spoke-specific group variables
    if [[ -d "${MOUNTED_GROUP_INVENTORY}/${spoke_cluster}" ]]; then
        find "${MOUNTED_GROUP_INVENTORY}/${spoke_cluster}/" -mindepth 1 -type d | while read -r dir; do
            echo "Process spoke group inventory file: ${dir}"
            process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
        done
    fi

    echo "Create host_vars directory"
    mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars

    # Copy spoke credentials to temporary location
    mkdir -p /tmp/"${spoke_cluster}" && chmod 700 /tmp/"${spoke_cluster}"

    # Copy common hypervisor credentials (shared across all spokes)
    if [[ -d "${MOUNTED_HOST_INVENTORY}/common/hypervisor" ]]; then
        cp -r "${MOUNTED_HOST_INVENTORY}/common/hypervisor" /tmp/"${spoke_cluster}"/hypervisor
    fi

    # Copy spoke-specific credentials (master0, etc.)
    if [[ -d "${MOUNTED_HOST_INVENTORY}/${spoke_cluster}" ]]; then
        cp -r "${MOUNTED_HOST_INVENTORY}/${spoke_cluster}/"* /tmp/"${spoke_cluster}"/
    fi
    ls -l /tmp/"${spoke_cluster}"/

    # Process spoke host variables
    find /tmp/"${spoke_cluster}"/ -mindepth 1 -type d | while read -r dir; do
        echo "Process spoke host inventory file: ${dir}"
        process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/host_vars/"$(basename "${dir}")"
    done

    # Process hub bastion credentials (for accessing hub cluster)
    if [[ -d "${MOUNTED_HOST_INVENTORY}/${hub_cluster}/bastion" ]]; then
        echo "Process hub bastion inventory file: ${MOUNTED_HOST_INVENTORY}/${hub_cluster}/bastion"
        process_inventory "${MOUNTED_HOST_INVENTORY}/${hub_cluster}/bastion" /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion
    fi

    # Configure SSH jump: Prow container -> hypervisor (hv6) -> bastion
    setup_ssh_jump "${MOUNTED_HOST_INVENTORY}" "${MOUNTED_GROUP_INVENTORY}" \
        /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion

    echo "Ansible inventory setup complete"
}
EOF

echo "Shared functions written to ${SHARED_DIR}/telco-kpis-common-functions.sh"
ls -l "${SHARED_DIR}/telco-kpis-common-functions.sh"
