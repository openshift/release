#!/bin/bash
set -e
set -o pipefail


ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
    echo "Detected skip.txt file — skipping the job"
    exit 0
fi

# backwards compatibility for process inventory step
if [[ -f "${SHARED_DIR}/process-inventory-completed" ]]; then
    echo "Copy inventory files"
    mkdir -pv ${ECO_CI_CD_INVENTORY_PATH}/group_vars
    mkdir -pv ${ECO_CI_CD_INVENTORY_PATH}/host_vars

    for file in ${SHARED_DIR}/*; do 
        if [[ "$file" == *"group_vars_"* || "$file" == *"host_vars_"* ]]; then
            DEST_DIR=$( basename $file | cut -d'_' -f1,2 )
            DEST_FILE=$( basename $file | cut -d'_' -f3 )
            cp $file ${ECO_CI_CD_INVENTORY_PATH}/$DEST_DIR/$DEST_FILE
        fi
    done
else

    echo "Create group_vars directory"
    mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/group_vars"

    echo "Copy group inventory files"
    # shellcheck disable=SC2154
    cp "${SHARED_DIR}/all" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all"
    cp "${SHARED_DIR}/bastions" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/bastions"

    echo "Create host_vars directory"
    mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/host_vars"

    echo "Copy host inventory files"
    cp "${SHARED_DIR}/bastion" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion"

fi

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi

export CLUSTER_NAME=${CLUSTER_NAME}
echo "CLUSTER_NAME=${CLUSTER_NAME}"

echo "NTO Configuration Environment Variables:"
echo "  CONTAINER_RUNTIME=${CONTAINER_RUNTIME}"
echo "  CGROUP_VERSION=${CGROUP_VERSION}"
echo "  RT_KERNEL=${RT_KERNEL}"
echo "  HUGEPAGES_DEFAULT_SIZE=${HUGEPAGES_DEFAULT_SIZE}"
echo "  HUGEPAGES_PAGES=${HUGEPAGES_PAGES}"
echo "  HIGH_POWER_CONSUMPTION=${HIGH_POWER_CONSUMPTION}"
echo "  PER_POD_POWER_MANAGEMENT=${PER_POD_POWER_MANAGEMENT}"
echo "  LABEL_FILTER=${LABEL_FILTER}"
echo "  DAY0_INSTALLATION=${DAY0_INSTALLATION}"


echo "Configure compute and NTO cluster settings"
cd /eco-ci-cd/

# Prepare extra variables for ansible playbook
EXTRA_VARS="kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"
EXTRA_VARS="${EXTRA_VARS} container_runtime=${CONTAINER_RUNTIME}"
EXTRA_VARS="${EXTRA_VARS} rt_kernel=${RT_KERNEL}"
EXTRA_VARS="${EXTRA_VARS} high_power_consumption=${HIGH_POWER_CONSUMPTION}"
EXTRA_VARS="${EXTRA_VARS} per_pod_power_management=${PER_POD_POWER_MANAGEMENT}"
EXTRA_VARS="${EXTRA_VARS} cgroup_version=${CGROUP_VERSION}"
EXTRA_VARS="${EXTRA_VARS} day0_installation=${DAY0_INSTALLATION}"

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

echo "Set bastion ssh configuration"
grep ansible_ssh_private_key -A 100 "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all" | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > "/tmp/temp_ssh_key"

chmod 600 "/tmp/temp_ssh_key"
BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all" | sed "s/'//g")


echo "Copy logs and artifacts to artifacts directory"
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /tmp/temp_ssh_key \
    "${BASTION_USER}@${BASTION_IP}":/tmp/artifacts/* "${ARTIFACT_DIR}"
