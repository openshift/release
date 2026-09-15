#!/bin/bash
set -euo pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

COMMON_VARIABLES="/var/common_variables"
CLUSTER_VARIABLES="/var/clusters/${TARGET_CLUSTER_NAME}"
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

echo "TARGET_CLUSTER_NAME=${TARGET_CLUSTER_NAME}"
echo "TARGET_HUB_VERSION=${VERSION}"

mkdir -p "${INVENTORY_PATH}/group_vars" "${INVENTORY_PATH}/host_vars"

echo "Processing common group_vars"
process_mount "${COMMON_VARIABLES}" false

echo "Processing target hub vars (${TARGET_CLUSTER_NAME})"
process_mount "${CLUSTER_VARIABLES}" true

echo "Processing hypervisor vars"
cp "${HYPERVISOR_VARIABLES}/hypervisor" "${INVENTORY_PATH}/host_vars/hypervisor"

cd /eco-ci-cd

echo "Running deploy-ocp-sno for target hub ${TARGET_CLUSTER_NAME} (version=${VERSION})"
EXTRA_VARS="release=${VERSION} cluster_name=${TARGET_CLUSTER_NAME} disconnected=true"
if [ "${DISABLE_INSIGHTS}" = "true" ]; then
  EXTRA_VARS="${EXTRA_VARS} disable_insights=true"
fi

ansible-playbook ./playbooks/deploy-ocp-sno.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "${EXTRA_VARS}"

# Write target hub inventory to SHARED_DIR (used by downstream steps).
# host_vars are copied flat — no prefix, as these are the "primary" hub files.
# group_vars/all is common across all clusters — same approach as seed hub.
echo "Copying target hub inventory to SHARED_DIR"
find "${INVENTORY_PATH}/host_vars" -maxdepth 1 -type f | while read -r f; do
  cp "$f" "${SHARED_DIR}/$(basename "$f")"
done
find "${INVENTORY_PATH}/group_vars" -maxdepth 1 -type f | while read -r f; do
  cp "$f" "${SHARED_DIR}/$(basename "$f")"
done
echo "${TARGET_CLUSTER_NAME}" > "${SHARED_DIR}/cluster_name"

echo "Preserving target hub inventory with target- prefix (readable after ibu-restore-seed-inventory)"
for key in bastion hypervisor master0 all bastions hypervisors nodes masters; do
  [[ -f "${SHARED_DIR}/${key}" ]] && cp "${SHARED_DIR}/${key}" "${SHARED_DIR}/target-${key}"
done

echo "Getting target hub cluster version"
HUB_KUBECONFIG="/home/telcov10n/project/generated/${TARGET_CLUSTER_NAME}/auth/kubeconfig"

BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=^ansible_user: ).*' "${INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

# The private key spans several lines in group_vars/all, take everything between the quotes
install -m 600 /dev/null "/tmp/temp_ssh_key"
sed -n "/^ansible_ssh_private_key: /,/'\$/p" "${INVENTORY_PATH}/group_vars/all" \
  | sed -e "s/^ansible_ssh_private_key: '//" -e "s/'\$//" > "/tmp/temp_ssh_key"

CLUSTER_VERSION=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i /tmp/temp_ssh_key "${BASTION_USER}@${BASTION_IP}" \
  "KUBECONFIG=${HUB_KUBECONFIG} oc get clusterversion version -ojsonpath='{.status.desired.version}'")

echo "Target hub cluster version: ${CLUSTER_VERSION}"
echo "${CLUSTER_VERSION}" > "${SHARED_DIR}/target_hub_version"
