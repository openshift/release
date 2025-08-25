#!/bin/bash
set -e
set -o pipefail

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

echo "Create group_vars directory"
mkdir -pv ${ECO_CI_CD_INVENTORY_PATH}/group_vars

echo "Copy group inventory files"
cp ${SHARED_DIR}/all ${ECO_CI_CD_INVENTORY_PATH}/group_vars/all
cp ${SHARED_DIR}/bastions ${ECO_CI_CD_INVENTORY_PATH}/group_vars/bastions

echo "Create host_vars directory"
mkdir -pv ${ECO_CI_CD_INVENTORY_PATH}/host_vars

echo "Copy host inventory files"
cp ${SHARED_DIR}/bastion ${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi
export CLUSTER_NAME=${CLUSTER_NAME}
echo "CLUSTER_NAME=${CLUSTER_NAME}"

echo "NTO Configuration Environment Variables:"
echo "  CONTAINER_RUNTIME=${CONTAINER_RUNTIME}"
echo "  RT_KERNEL=${RT_KERNEL}"
echo "  HUGEPAGES_DEFAULT_SIZE=${HUGEPAGES_DEFAULT_SIZE}"
echo "  HUGEPAGES_PAGES=${HUGEPAGES_PAGES}"
echo "  HIGH_POWER_CONSUMPTION=${HIGH_POWER_CONSUMPTION}"
echo "  PER_POD_POWER_MANAGEMENT=${PER_POD_POWER_MANAGEMENT}"
echo "  LABEL_FILTER=${LABEL_FILTER}"


echo "Configure compute and NTO cluster settings"
cd /eco-ci-cd/

# Prepare extra variables for ansible playbook
EXTRA_VARS="kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"
EXTRA_VARS="${EXTRA_VARS} container_runtime=${CONTAINER_RUNTIME}"
EXTRA_VARS="${EXTRA_VARS} rt_kernel=${RT_KERNEL}"
EXTRA_VARS="${EXTRA_VARS} high_power_consumption=${HIGH_POWER_CONSUMPTION}"
EXTRA_VARS="${EXTRA_VARS} per_pod_power_management=${PER_POD_POWER_MANAGEMENT}"
EXTRA_VARS="${EXTRA_VARS} artifacts_folder=${ARTIFACT_DIR}"

# Handle hugepages configuration
if [[ "${HUGEPAGES_PAGES}" != "[]" && -n "${HUGEPAGES_PAGES}" ]]; then
    EXTRA_VARS="${EXTRA_VARS} hugepages='{\"size\": \"${HUGEPAGES_DEFAULT_SIZE}\", \"pages\": ${HUGEPAGES_PAGES}}'"
else
    EXTRA_VARS="${EXTRA_VARS} hugepages='{\"size\": \"${HUGEPAGES_DEFAULT_SIZE}\"}'"
fi

echo "Running ansible-playbook with extra vars: ${EXTRA_VARS}"
export ANSIBLE_REMOTE_TEMP="/tmp"
ansible-playbook ./playbooks/compute/config-cluster.yml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "${EXTRA_VARS}"

echo "Copy generated artifacts to shared directory"
cp -v ${ARTIFACT_DIR}/*.yml ${SHARED_DIR}/ 2>/dev/null || echo "No YAML artifacts found to copy"

echo "Compute-NTO configuration completed successfully"
