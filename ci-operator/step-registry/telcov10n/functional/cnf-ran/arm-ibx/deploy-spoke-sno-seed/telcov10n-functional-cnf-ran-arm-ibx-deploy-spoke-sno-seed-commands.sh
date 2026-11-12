#!/bin/bash
set -euo pipefail

if [[ -f "${SHARED_DIR}/skip.txt" ]]; then
  echo "Detected skip.txt — skipping the job"
  exit 0
fi

# Require explicit paths so a missing lane setting cannot select another layout.
: "${CLUSTER_NAME:?CLUSTER_NAME must be configured}"
: "${VERSION:?VERSION must be configured}"
: "${ZTP_GIT_REPO:?ZTP_GIT_REPO must be configured}"
: "${ZTP_GIT_BRANCH:?ZTP_GIT_BRANCH must be configured}"
if [[ "${SPOKE_ARCH:?SPOKE_ARCH must be configured}" != "multi" ]]; then
  echo "ARM IBX requires SPOKE_ARCH=multi" >&2
  exit 1
fi
case "${ARM_IBX_DEPLOY_ROLE:?ARM_IBX_DEPLOY_ROLE must be configured}" in
  seed)
    SPOKE_NAME="${SEED_SPOKE_CLUSTER:?SEED_SPOKE_CLUSTER must be configured}"
    : "${ZTP_SEED_CLUSTERS_PATH:?ZTP_SEED_CLUSTERS_PATH must be configured}"
    : "${ZTP_SEED_POLICIES_PATH:?ZTP_SEED_POLICIES_PATH must be configured}"
    ZTP_CLUSTERS_PATH="${ZTP_SEED_CLUSTERS_PATH}"
    ZTP_POLICIES_PATH="${ZTP_SEED_POLICIES_PATH}"
    ;;
  target)
    SPOKE_NAME="${TARGET_SPOKE_CLUSTER:?TARGET_SPOKE_CLUSTER must be configured}"
    : "${ZTP_TARGET_CLUSTERS_PATH:?ZTP_TARGET_CLUSTERS_PATH must be configured}"
    : "${ZTP_TARGET_POLICIES_PATH:?ZTP_TARGET_POLICIES_PATH must be configured}"
    ZTP_CLUSTERS_PATH="${ZTP_TARGET_CLUSTERS_PATH}"
    ZTP_POLICIES_PATH="${ZTP_TARGET_POLICIES_PATH}"
    ;;
  *)
    echo "ARM_IBX_DEPLOY_ROLE must be seed or target" >&2
    exit 1
    ;;
esac

INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"
mkdir -p "${INVENTORY_PATH}/group_vars" "${INVENTORY_PATH}/host_vars"

for inventory in all bastions hypervisors nodes masters; do
  cp "${SHARED_DIR}/${inventory}" "${INVENTORY_PATH}/group_vars/${inventory}"
done
for inventory in bastion hypervisor; do
  cp "${SHARED_DIR}/${inventory}" "${INVENTORY_PATH}/host_vars/${inventory}"
done

# build-inventory.py discovers master-spoke; Ansible loads its variables from this file.
SPOKE_HOST_VARS="${INVENTORY_PATH}/host_vars/master-spoke"
umask 077
: > "${SPOKE_HOST_VARS}"
chmod 600 "${SPOKE_HOST_VARS}"
trap 'rm -f "${SPOKE_HOST_VARS}"' EXIT
cd /eco-ci-cd

if [[ "${ARM_IBX_DEPLOY_ROLE}" == "seed" ]]; then
  for field in hostname bmc_user bmc_password; do
    value=$(cat "/var/host_variables/${CLUSTER_NAME}/spoke-master0/${field}")
    printf "%s: '%s'\n" "${field}" "${value//\'/\'\'}"
  done > "${SPOKE_HOST_VARS}"
else
  # The target still uses the BMC credentials from its bastion inventory.
  ansible-inventory -i ./inventories/ocp-deployment/build-inventory.py --host bastion |
    python3 -c '
import json
import sys

bastion = json.load(sys.stdin)
json.dump({"hostname": sys.argv[1],
           "bmc_user": bastion["bmc_user"], "bmc_password": bastion["bmc_password"]}, sys.stdout)
' "${SPOKE_NAME}" > "${SPOKE_HOST_VARS}"
fi

KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

echo "Deploying ARM IBX ${ARM_IBX_DEPLOY_ROLE} spoke ${SPOKE_NAME} on hub ${CLUSTER_NAME}"
echo "ZTP branch: ${ZTP_GIT_BRANCH}"
echo "ZTP clusters path: ${ZTP_CLUSTERS_PATH}"
echo "ZTP policies path: ${ZTP_POLICIES_PATH}"

ansible-playbook ./playbooks/ran/deploy-spoke-ztp-mno.yaml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} \
    spoke_cluster=${SPOKE_NAME} \
    ocp_version=${VERSION} \
    arch=${SPOKE_ARCH} \
    force_cleanup=false \
    ztp_git_repo_url=${ZTP_GIT_REPO} \
    ztp_clusters_git_path=${ZTP_CLUSTERS_PATH} \
    ztp_policies_git_path=${ZTP_POLICIES_PATH} \
    ztp_git_branch=${ZTP_GIT_BRANCH}"
