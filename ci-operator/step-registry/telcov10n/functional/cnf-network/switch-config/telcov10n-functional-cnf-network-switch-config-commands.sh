#!/bin/bash
set -e
set -o pipefail

COMMON_VARIABLES="/var/common_variables"
SWITCH_VARIABLES="/var/switches"
INVENTORY_PATH="/eco-ci-cd/inventories/cnf"

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

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

# hlxcl2, hlxcl3 and hlxcl7 all sit behind the same TLV2 switch.
switch_for_cluster() {
  case "${CLUSTER_NAME}" in
    kni-qe-92) echo "rdu3_switch" ;;
    hlxcl*)    echo "tlv2_switch" ;;
    *)         echo "" ;;
  esac
}

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

echo "Processing switch vars"
SWITCH="$(switch_for_cluster)"
if [ -z "${SWITCH}" ]; then
  echo "Error: no switch mapped for ${CLUSTER_NAME}"
  exit 1
fi
SWITCH_FILE="${SWITCH_VARIABLES}/${SWITCH}"
if [ ! -f "${SWITCH_FILE}" ]; then
  echo "Error: switch of ${CLUSTER_NAME} not found in ${SWITCH_VARIABLES}"
  exit 1
fi
cp "${SWITCH_FILE}" "${INVENTORY_PATH}/host_vars/switch"

echo "Set OCP_NIC env var"
if [[ -f "${SHARED_DIR}/ocp_nic" ]]; then
    OCP_NIC=$(cat "${SHARED_DIR}/ocp_nic")
fi
export OCP_NIC=${OCP_NIC}
echo OCP_NIC="${OCP_NIC}"

echo "Set SECONDARY_NIC env var"
if [[ -f "${SHARED_DIR}/secondary_nic" ]]; then
    SECONDARY_NIC=$(cat "${SHARED_DIR}/secondary_nic")
fi
export SECONDARY_NIC=${SECONDARY_NIC}
echo SECONDARY_NIC="${SECONDARY_NIC}"

cd /eco-ci-cd/

export ANSIBLE_REMOTE_TEMP="/tmp"
ansible-playbook ./playbooks/cnf/switch-config.yaml -i ./inventories/cnf/switch-config.yaml \
    --extra-vars "cluster_name=$CLUSTER_NAME artifact_dest_dir=$SHARED_DIR ocp_nic=$OCP_NIC version=$VERSION secondary_nic=$SECONDARY_NIC"

cp "${INVENTORY_PATH}/host_vars/switch" "${SHARED_DIR}"/
