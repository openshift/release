#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

# MOUNTED_HOST_INVENTORY="/var/host_variables"
COMMON_VARIABLES="/var/common_variables"
CLUSTER_VARIABLES="/var/clusters/${CLUSTER_NAME}"
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
    kni-qe-99)                        echo "helix41-lab-eng-tlv2-redhat-com" ;;
    fthub-01|kni-qe-106|kni-qe-110)   echo "helix107-hv-telcoqe-eng-rdu2-dc-redhat-com" ;;
    kni-qe-108|kni-qe-111)            echo "helix89-telcoqe-eng-rdu2-dc-redhat-com" ;;
    kni-qe-127|kni-qe-128)                       echo "helix118-hv-telcoqe-eng-rdu2-dc-redhat-com" ;;
    *)                                echo "" ;;
  esac
}

echo "CLUSTER_NAME=${CLUSTER_NAME}"

mkdir -p "${INVENTORY_PATH}/group_vars" "${INVENTORY_PATH}/host_vars"

echo "Processing common group_vars"
process_mount "${COMMON_VARIABLES}" false

echo "Processing cluster vars (${CLUSTER_NAME})"
process_mount "${CLUSTER_VARIABLES}" true

echo "Processing hypervisor vars"
HYPERVISOR="$(hypervisor_for_cluster)"
if [ -z "${HYPERVISOR}" ]; then
  echo "No hypervisor mapped for ${CLUSTER_NAME} — skipping host_vars/hypervisor"
else
  HYPERVISOR_FILE="${HYPERVISOR_VARIABLES}/${HYPERVISOR}"
  if [ ! -f "${HYPERVISOR_FILE}" ]; then
    echo "Error: hypervisor of ${CLUSTER_NAME} not found in ${HYPERVISOR_VARIABLES}"
    exit 1
  fi
  cp "${HYPERVISOR_FILE}" "${INVENTORY_PATH}/host_vars/hypervisor"
fi

cd /eco-ci-cd

echo "Copy host inventory files from SHARED_DIR"
cp ${SHARED_DIR}/all /eco-ci-cd/inventories/ocp-deployment/group_vars/all
cp ${SHARED_DIR}/bastion /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion
cp ${SHARED_DIR}/hypervisor /eco-ci-cd/inventories/ocp-deployment/host_vars/hypervisor

cd /eco-ci-cd
ansible-playbook -vv playbooks/ran/create-spoke-masters.yml \
  -i inventories/ocp-deployment/build-inventory.py
