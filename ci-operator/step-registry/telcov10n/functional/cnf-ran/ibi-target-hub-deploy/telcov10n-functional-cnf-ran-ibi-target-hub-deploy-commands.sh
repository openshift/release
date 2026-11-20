#!/bin/bash
set -euo pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

MOUNTED_HOST_INVENTORY="/var/host_variables"

cleanup() {
  local rc=$?
  trap - EXIT
  rm -rf -- "${TEMP_DIR}" || rc=1
  exit "${rc}"
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

  find "$directory" -type f | while IFS= read -r filename; do
    if [[ $filename == *"secretsync-vault-source-path"* ]]; then
      continue
    fi
    local content varname
    content=$(cat "$filename")
    varname=$(basename "${filename}")
    if [[ "$content" == *$'\n'* ]]; then
      printf '%s: |\n' "${varname}"
      printf '%s\n' "$content" | sed 's/^/  /'
    else
      printf "%s: '%s'\n" "${varname}" "${content//\'/\'\'}"
    fi
  done > "${dest_file}"
}

echo "TARGET_CLUSTER_NAME=${TARGET_CLUSTER_NAME}"
echo "TARGET_HUB_VERSION=${VERSION}"

echo "Processing common group_vars"
mkdir /eco-ci-cd/inventories/ocp-deployment/group_vars

find /var/group_variables/common/ -mindepth 1 -maxdepth 1 -type d | while read -r dir; do
  echo "  group_var: $(basename "${dir}")"
  process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
done

echo "Processing target hub group_vars (${TARGET_CLUSTER_NAME})"
find "/var/group_variables/${TARGET_CLUSTER_NAME}/" -mindepth 1 -maxdepth 1 -type d | while read -r dir; do
  echo "  group_var: $(basename "${dir}")"
  process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename "${dir}")"
done

echo "Processing target hub host_vars (${TARGET_CLUSTER_NAME})"
mkdir /eco-ci-cd/inventories/ocp-deployment/host_vars

find "${MOUNTED_HOST_INVENTORY}/${TARGET_CLUSTER_NAME}/" -mindepth 1 -maxdepth 1 -type d | while read -r dir; do
  echo "  host_var: $(basename "${dir}")"
  process_inventory "$dir" /eco-ci-cd/inventories/ocp-deployment/host_vars/"$(basename "${dir}")"
done

cd /eco-ci-cd

echo "Running deploy-ocp-sno for target hub ${TARGET_CLUSTER_NAME} (version=${VERSION})"
EXTRA_VARS="release=${VERSION} cluster_name=${TARGET_CLUSTER_NAME} disconnected=true"
if [ "${DISABLE_INSIGHTS}" = "true" ]; then
  EXTRA_VARS="${EXTRA_VARS} disable_insights=true"
fi

# Inventory preserves PEM newlines; extra-var precedence overrides the legacy certificate formatter.
ansible-playbook ./playbooks/deploy-ocp-sno.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "${EXTRA_VARS}" \
  --extra-vars '{"disconnected_registry_cert_formatted":"{{ disconnected_registry_cert }}"}'

# Write target hub inventory to SHARED_DIR (used by downstream steps).
# host_vars are copied flat — no prefix, as these are the "primary" hub files.
# group_vars/all is common across all clusters — same approach as seed hub.
echo "Copying target hub inventory to SHARED_DIR"
find /eco-ci-cd/inventories/ocp-deployment/host_vars -maxdepth 1 -type f | while read -r f; do
  cp "$f" "${SHARED_DIR}/$(basename "$f")"
done
find /eco-ci-cd/inventories/ocp-deployment/group_vars -maxdepth 1 -type f | while read -r f; do
  cp "$f" "${SHARED_DIR}/$(basename "$f")"
done
echo "${TARGET_CLUSTER_NAME}" > "${SHARED_DIR}/cluster_name"

echo "Preserving target hub inventory with target- prefix (readable after ibu-restore-seed-inventory)"
for key in bastion hypervisor master0 all bastions hypervisors nodes masters; do
  [[ -f "${SHARED_DIR}/${key}" ]] && cp "${SHARED_DIR}/${key}" "${SHARED_DIR}/target-${key}"
done

echo "Getting target hub cluster version"
HUB_KUBECONFIG="/home/telcov10n/project/generated/${TARGET_CLUSTER_NAME}/auth/kubeconfig"

TEMP_DIR=$(mktemp -d /tmp/ibi-target-hub-deploy.XXXXXX)
trap cleanup EXIT
install -m 600 /var/group_variables/common/all/ansible_ssh_private_key "${TEMP_DIR}/ssh-key"

BASTION_IDENTITY=$(
  exec 2>"${TEMP_DIR}/inventory.log" || exit 1
  ansible-inventory -i ./inventories/ocp-deployment/build-inventory.py --host bastion |
    jq -er '[.ansible_host, .ansible_user] | join(" ")'
)
read -r BASTION_IP BASTION_USER <<< "${BASTION_IDENTITY}"
[[ -n "${BASTION_IP}" && -n "${BASTION_USER}" ]]

CLUSTER_VERSION=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "${TEMP_DIR}/ssh-key" "${BASTION_USER}@${BASTION_IP}" \
  "KUBECONFIG=${HUB_KUBECONFIG} oc get clusterversion version -ojsonpath='{.status.desired.version}'" \
  2>"${TEMP_DIR}/version.log")

echo "Target hub cluster version: ${CLUSTER_VERSION}"
echo "${CLUSTER_VERSION}" > "${SHARED_DIR}/target_hub_version"
