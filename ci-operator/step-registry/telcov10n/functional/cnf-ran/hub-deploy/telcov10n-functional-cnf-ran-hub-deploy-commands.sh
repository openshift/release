#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

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

echo "Running deploy-ocp-sno for ${CLUSTER_NAME} (version=${VERSION})"
EXTRA_VARS="release=${VERSION} cluster_name=${CLUSTER_NAME} disconnected=true release_age_max_days=${MULTISTAGE_PARAM_OVERRIDE_RELEASE_AGE_MAX_DAYS}"
if [ "${DISABLE_INSIGHTS}" = "true" ]; then
  EXTRA_VARS="${EXTRA_VARS} disable_insights=true"
fi

ansible-playbook ./playbooks/deploy-ocp-sno.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "${EXTRA_VARS}"

echo "Copying inventory to SHARED_DIR"
cp -r "${INVENTORY_PATH}"/host_vars/* "${SHARED_DIR}"/
cp -r "${INVENTORY_PATH}"/group_vars/* "${SHARED_DIR}"/

echo "Preserving seed hub inventory with seed- prefix for later restore"
for key in bastion hypervisor master0 all bastions hypervisors nodes masters; do
  [[ -f "${SHARED_DIR}/${key}" ]] && cp "${SHARED_DIR}/${key}" "${SHARED_DIR}/seed-${key}"
done

echo "Getting hub cluster version"
HUB_KUBECONFIG="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${INVENTORY_PATH}/group_vars/all" | sed "s/'//g")

# The private key spans several lines in group_vars/all, take everything between the quotes
install -m 600 /dev/null "/tmp/temp_ssh_key"
sed -n "/^ansible_ssh_private_key: /,/'\$/p" "${INVENTORY_PATH}/group_vars/all" \
  | sed -e "s/^ansible_ssh_private_key: '//" -e "s/'\$//" > "/tmp/temp_ssh_key"

CLUSTER_VERSION=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i /tmp/temp_ssh_key "${BASTION_USER}@${BASTION_IP}" \
  "KUBECONFIG=${HUB_KUBECONFIG} oc get clusterversion version -ojsonpath='{.status.desired.version}'")

echo "Cluster version: ${CLUSTER_VERSION}"
echo "${CLUSTER_VERSION}" > "${SHARED_DIR}/cluster_version"
