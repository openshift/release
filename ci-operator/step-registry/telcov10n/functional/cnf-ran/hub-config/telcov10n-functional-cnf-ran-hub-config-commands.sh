#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"
COMMON_VARIABLES="/var/common_variables"

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

echo "Create inventory directories"
mkdir -p "${INVENTORY_PATH}/group_vars" "${INVENTORY_PATH}/host_vars"

echo "Processing common group_vars"
process_mount "${COMMON_VARIABLES}" false

echo "Copying host_vars from SHARED_DIR"
cp "${SHARED_DIR}/bastion" "${INVENTORY_PATH}/host_vars/bastion"
cp "${SHARED_DIR}/master0" "${INVENTORY_PATH}/host_vars/master0"

if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
  CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi
echo "CLUSTER_NAME=${CLUSTER_NAME}"

KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

PROJECT_DIR="/tmp"
# The private key spans several lines in group_vars/all, take everything between the quotes
install -m 600 /dev/null "${PROJECT_DIR}/ansible_ssh_key"
sed -n "/^ansible_ssh_private_key: /,/'\$/p" "${INVENTORY_PATH}/group_vars/all" \
  | sed -e "s/^ansible_ssh_private_key: '//" -e "s/'\$//" > "${PROJECT_DIR}/ansible_ssh_key"
export ANSIBLE_PRIVATE_KEY_FILE="${PROJECT_DIR}/ansible_ssh_key"

export ANSIBLE_SSH_RETRIES=3
export ANSIBLE_TIMEOUT=600
export ANSIBLE_HOST_KEY_CHECKING=False

VERSION_TAG=$(echo "${VERSION}" | tr '.' '-')
export VERSION_TAG
echo "VERSION_TAG=${VERSION_TAG}"

HUB_OPERATORS=$(echo "${HUB_OPERATORS}" | sed "s/\${VERSION_TAG}/${VERSION_TAG}/g")
echo "HUB_OPERATORS=${HUB_OPERATORS}"

cd /eco-ci-cd/

echo "Deploying hub operators (VERSION=${VERSION}, VERSION_TAG=${VERSION_TAG})"

if [[ "$VERSION" == "4.14" ]]; then
  echo "Applying ose-kube-rbac-proxy workaround for 4.14"
  ansible-playbook playbooks/ran/mirror-ose-kube-rbac-proxy-wa.yml \
    -i inventories/ocp-deployment/build-inventory.py \
    --extra-vars "version=$VERSION"
fi

SKIP_REGISTRY_CLEANUP=""
if [[ "$VERSION" == "4.14" ]]; then
  SKIP_REGISTRY_CLEANUP="ocp_operator_mirror_skip_internal_registry_cleanup=true"
fi

echo "Running deploy-ocp-operators"
ansible-playbook ./playbooks/deploy-ocp-operators.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} version=$VERSION disconnected=$DISCONNECTED operators='$HUB_OPERATORS' $SKIP_REGISTRY_CLEANUP"

echo "Configuring LVM storage"
ansible-playbook playbooks/ran/hub-sno-configure-lvm-storage.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --private-key="${PROJECT_DIR}/ansible_ssh_key" \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH}" \
  --extra-vars "{\"lvm_local_volumes\": ${LVM_LOCAL_VOLUMES}}" -vv

echo "Configuring ACM"
ansible-playbook playbooks/ran/hub-sno-configure-acm.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} ocp_version=$VERSION" -vv

echo "Configuring kustomize plugin"
ansible-playbook playbooks/ran/hub-sno-configure-kustomize-plugin.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} ocp_version=$VERSION" -vv

echo "Configuring GitOps"
ansible-playbook playbooks/ran/hub-sno-configure-gitops.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} gitlab_repo_url=${GITLAB_REPO_URL}" -vv
