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

# The MNO playbook also supports SNO. Its masters group must describe the spoke,
# not the hub master0 saved in SHARED_DIR. Use the same BMC credentials that the
# previous SNO playbook read from the bastion's inventory.
INVENTORY_FILE="${INVENTORY_PATH}/arm-ibx.yaml"
umask 077
: > "${INVENTORY_FILE}"
chmod 600 "${INVENTORY_FILE}"
trap 'rm -f "${INVENTORY_FILE}"' EXIT
cd /eco-ci-cd
ansible-inventory -i ./inventories/ocp-deployment/build-inventory.py --host bastion |
  python3 -c '
import json
import sys

bastion = json.load(sys.stdin)
spoke = {"hostname": sys.argv[1],
         "bmc_user": bastion["bmc_user"], "bmc_password": bastion["bmc_password"]}
json.dump({"all": {"children": {
    "bastions": {"hosts": {"bastion": {}}},
    "vm_hosts": {"children": {"hypervisors": {"hosts": {"hypervisor": {}}}}},
    "nodes": {"children": {"masters": {"hosts": {"arm-ibx-spoke": spoke}}}},
}}}, sys.stdout)
' "${SPOKE_NAME}" > "${INVENTORY_FILE}"

KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

echo "Deploying ARM IBX ${ARM_IBX_DEPLOY_ROLE} spoke ${SPOKE_NAME} on hub ${CLUSTER_NAME}"
echo "ZTP branch: ${ZTP_GIT_BRANCH}"
echo "ZTP clusters path: ${ZTP_CLUSTERS_PATH}"
echo "ZTP policies path: ${ZTP_POLICIES_PATH}"

ansible-playbook ./playbooks/ran/deploy-spoke-ztp-mno.yaml \
  -i "${INVENTORY_FILE}" \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} \
    spoke_cluster=${SPOKE_NAME} \
    ocp_version=${VERSION} \
    arch=${SPOKE_ARCH} \
    force_cleanup=false \
    ztp_git_repo_url=${ZTP_GIT_REPO} \
    ztp_clusters_git_path=${ZTP_CLUSTERS_PATH} \
    ztp_policies_git_path=${ZTP_POLICIES_PATH} \
    ztp_git_branch=${ZTP_GIT_BRANCH}"
