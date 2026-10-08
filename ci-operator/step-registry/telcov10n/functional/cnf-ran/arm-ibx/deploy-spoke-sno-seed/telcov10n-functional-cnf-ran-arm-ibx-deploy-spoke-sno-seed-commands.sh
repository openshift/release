#!/bin/bash
set -euo pipefail

if [[ -f "${SHARED_DIR}/skip.txt" ]]; then
  echo "Detected skip.txt — skipping the job"
  exit 0
fi

# Require explicit paths so a missing lane setting cannot select another layout.
: "${CLUSTER_NAME:?CLUSTER_NAME must be configured}"
: "${SPOKE_CLUSTER:?SPOKE_CLUSTER must be configured}"
: "${ZTP_GIT_REPO:?ZTP_GIT_REPO must be configured}"
: "${ZTP_GIT_BRANCH:?ZTP_GIT_BRANCH must be configured}"
case "${ARM_IBX_DEPLOY_ROLE:?ARM_IBX_DEPLOY_ROLE must be configured}" in
  seed)
    : "${ZTP_SEED_CLUSTERS_PATH:?ZTP_SEED_CLUSTERS_PATH must be configured}"
    : "${ZTP_SEED_POLICIES_PATH:?ZTP_SEED_POLICIES_PATH must be configured}"
    ZTP_CLUSTERS_PATH="${ZTP_SEED_CLUSTERS_PATH}"
    ZTP_POLICIES_PATH="${ZTP_SEED_POLICIES_PATH}"
    ;;
  target)
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
for inventory in bastion hypervisor master0; do
  cp "${SHARED_DIR}/${inventory}" "${INVENTORY_PATH}/host_vars/${inventory}"
done

KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

echo "Deploying ARM IBX ${ARM_IBX_DEPLOY_ROLE} spoke ${SPOKE_CLUSTER} on hub ${CLUSTER_NAME}"
echo "ZTP branch: ${ZTP_GIT_BRANCH}"
echo "ZTP clusters path: ${ZTP_CLUSTERS_PATH}"
echo "ZTP policies path: ${ZTP_POLICIES_PATH}"

cd /eco-ci-cd
ansible-playbook ./playbooks/ran/deploy-spoke-sno.yaml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} \
    spoke_clusters='${SPOKE_CLUSTER}' \
    ztp_git_repo_url=${ZTP_GIT_REPO} \
    ztp_clusters_git_path=${ZTP_CLUSTERS_PATH} \
    ztp_policies_git_path=${ZTP_POLICIES_PATH} \
    ztp_git_repo_branch=${ZTP_GIT_BRANCH}"
