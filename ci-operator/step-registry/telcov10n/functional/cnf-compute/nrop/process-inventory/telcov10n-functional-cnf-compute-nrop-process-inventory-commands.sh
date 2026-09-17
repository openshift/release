#!/bin/bash
set -e
set -o pipefail
set -x

COMMON_VARIABLES="/var/common_variables"
HYPERVISOR_VARIABLES="/var/hypervisors"
INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

function copy_to_shared_dir() {
	if [ -z "$1" ]
	then
		echo "missing directory to copy"
		exit 1
	fi

	echo "copying files to $1..."
	for filename in $1/*; do cp $filename "${SHARED_DIR}/$(basename $1)_$(basename $filename)"; done

}

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
        helix47)   echo "helix47-lab-eng-tlv2-redhat-com" ;;
        kni-qe-52) echo "hv16-telco5gran-eng-rdu2-redhat-com" ;;
        hlxcl9)    echo "ocp-edge92-lab-eng-tlv2-redhat-com" ;;
        *)         echo "" ;;
    esac
}

main() {

    echo "Set CLUSTER_NAME env var"
    if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
        CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
    fi
    export CLUSTER_NAME=${CLUSTER_NAME}
    echo CLUSTER_NAME="${CLUSTER_NAME}"

    mkdir -pv "${INVENTORY_PATH}/group_vars" "${INVENTORY_PATH}/host_vars"

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

    echo "Store inventory in SHARED_DIR"
    copy_to_shared_dir "${INVENTORY_PATH}/host_vars"
    copy_to_shared_dir "${INVENTORY_PATH}/group_vars"

    echo "Flag process-inventory as completed"
    touch "${SHARED_DIR}/process-inventory-completed"
}

main
