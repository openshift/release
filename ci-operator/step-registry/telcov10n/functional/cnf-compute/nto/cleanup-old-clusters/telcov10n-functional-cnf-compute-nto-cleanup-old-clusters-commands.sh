#!/bin/bash
set -e
set -o pipefail
set -x

COMMON_VARIABLES="/var/common_variables"
HYPERVISOR_VARIABLES="/var/hypervisors"
INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

install_vars() {
    local src="$1"
    local allow_host_vars="$2"
    local base dest_dir name

    base="$(basename "$src")"

    case "$base" in
        ansible_group_*)
            dest_dir="${INVENTORY_PATH}/group_vars"
            name="${base#ansible_group_}"
            ;;
        *)
            if [ "${allow_host_vars}" != "true" ]; then
                echo "  skipped a file that is not a group var"
                return 0
            fi
            dest_dir="${INVENTORY_PATH}/host_vars"
            case "$base" in
                bastion*) name="bastion" ;;
                *)        name="${base}" ;;
            esac
            ;;
    esac
    cp "$src" "${dest_dir}/${name}"
}

process_mount() {
    local directory="$1"
    local allow_host_vars="$2"

    if [ ! -d "$directory" ]; then
        echo "Error: '$directory' is not a valid directory"
        return 1
    fi

    # -L so that files exposed as symlinks by the secrets mount are matched as regular files
    while IFS= read -r filename; do
        install_vars "$filename" "${allow_host_vars}"
    done < <(find -L "$directory" -maxdepth 1 -type f ! -name '..*' | sort)
}

# Hypervisors are shared between clusters, so the whole hypervisors group is mounted and the
# right one is picked here.
hypervisor_for_cluster() {
    case "${CLUSTER_NAME}" in
        hlxcl15) echo "ocp-edge91-lab-eng-tlv2-redhat-com" ;;
        *)       echo "" ;;
    esac
}

main() {

    echo "Set CLUSTER_NAME env var"
    if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
        CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
    fi
    export CLUSTER_NAME=${CLUSTER_NAME}
    echo CLUSTER_NAME="${CLUSTER_NAME}"

    mkdir -p "${INVENTORY_PATH}/group_vars" "${INVENTORY_PATH}/host_vars"

    echo "Processing common group_vars"
    process_mount "${COMMON_VARIABLES}" false

    echo "Processing cluster vars (${CLUSTER_NAME})"
    process_mount "/var/clusters/${CLUSTER_NAME}" true

    echo "Processing hypervisor vars"
    HYPERVISOR="$(hypervisor_for_cluster)"
    if [ -z "${HYPERVISOR}" ]; then
        echo "Error: no hypervisor mapped for ${CLUSTER_NAME}"
        exit 1
    fi
    HYPERVISOR_FILE="${HYPERVISOR_VARIABLES}/${HYPERVISOR}"
    if [ ! -f "${HYPERVISOR_FILE}" ]; then
        echo "Error: hypervisor of ${CLUSTER_NAME} not found in ${HYPERVISOR_VARIABLES}"
        exit 1
    fi
    cp "${HYPERVISOR_FILE}" "${INVENTORY_PATH}/host_vars/hypervisor"

    cd /eco-ci-cd

    echo "Clean old clusters"
    ansible-playbook ./playbooks/compute/delete_old_clusters.yml \
        -e "cluster_name=${CLUSTER_NAME}" \
        -i ./inventories/ocp-deployment/build-inventory.py
}

main
