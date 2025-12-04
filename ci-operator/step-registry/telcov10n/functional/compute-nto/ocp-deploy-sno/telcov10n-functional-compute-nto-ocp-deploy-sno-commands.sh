#!/bin/bash
set -e
set -o pipefail
set -x

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

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

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi
export CLUSTER_NAME=${CLUSTER_NAME}
echo "CLUSTER_NAME=${CLUSTER_NAME}"

cd /eco-ci-cd

echo "Clean old clusters"
ansible-playbook ./playbooks/compute/delete_old_clusters.yml \
    -i ./inventories/ocp-deployment/build-inventory.py

echo "Deploy SNO OCP for compute-nto testing"
ansible-playbook ./playbooks/deploy-ocp-sno.yml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "release=${VERSION}" \
    --extra-vars "cluster_name=${CLUSTER_NAME}" \
    --extra-vars "ocp_version_facts_release_type=${OCP_VERSION_RELEASE_TYPE}" \
    --extra-vars "ocp_version_release_age_max_days=${OCP_VERSION_RELEASE_AGE_MAX_DAYS}" \
    --extra-vars "disconnected=${DISCONNECTED}" \
    --extra-vars "ipv4_only=${IPV4_ONLY}" \
    --extra-vars "ipv6_only=${IPV6_ONLY}" \
    --extra-vars "extra_manifest_folder=${EXTRA_MANIFEST_FOLDER}"
