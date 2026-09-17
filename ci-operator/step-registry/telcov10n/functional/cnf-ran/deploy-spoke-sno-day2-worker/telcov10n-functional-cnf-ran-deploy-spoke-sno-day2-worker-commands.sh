#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"
COMMON_VARIABLES="/var/common_variables"
HYPERVISOR_VARIABLES="/var/hypervisors"

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

echo "CLUSTER_NAME=${CLUSTER_NAME}"

if [ "${CLUSTER_NAME}" != "kni-qe-106" ]; then
    echo "ERROR: Only CLUSTER_NAME=kni-qe-106 is supported by this step."
    echo "This step mounts credentials specific to the kni-qe-106 hub."
    exit 1
fi

echo "Create inventory directories"
mkdir -p "${INVENTORY_PATH}/group_vars" "${INVENTORY_PATH}/host_vars"

echo "Processing common group_vars"
process_mount "${COMMON_VARIABLES}" false

echo "Processing cluster vars for ${CLUSTER_NAME}"
process_mount "/var/clusters/${CLUSTER_NAME}" true

echo "Processing hypervisor vars"
cp "${HYPERVISOR_VARIABLES}/hypervisor" "${INVENTORY_PATH}/host_vars/hypervisor"

# Set kubeconfig path
KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

# Parse first spoke cluster name from array format, e.g. "['kni-qe-107']" → "kni-qe-107"
SPOKE_CLUSTER_NAME=$(echo "${SPOKE_CLUSTER}" | tr -d "[]' ")

echo "Running day 2 worker expansion for SNO spoke cluster: ${SPOKE_CLUSTER_NAME}"
ansible-playbook ./playbooks/ran/deploy-ocp-sno-day2-worker.yml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} \
        spoke_cluster_name=${SPOKE_CLUSTER_NAME} \
        day2_branch=${ZTP_GIT_BRANCH_DAY2_WORKER}"
