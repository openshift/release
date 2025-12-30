#!/bin/bash
set -e
set -o pipefail

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

if [[ ! -f "${SHARED_DIR}/gotest-completed" ]]; then
  echo "Gotests did not complete, skipping reporter step"
  exit 0
fi

echo "Create group_vars directory"
mkdir -pv "${ECO_CI_CD_INVENTORY_PATH}/group_vars"

echo "Copy group inventory files"
# shellcheck disable=SC2154
cp "${SHARED_DIR}/all" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all"
cp "${SHARED_DIR}/bastions" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/bastions"

echo "Create host_vars directory"
mkdir -pv "${ECO_CI_CD_INVENTORY_PATH}/host_vars"

echo "Copy host inventory files"
cp "${SHARED_DIR}/bastion" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion"

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi

export CLUSTER_NAME="${CLUSTER_NAME}"
echo "CLUSTER_NAME=${CLUSTER_NAME}"

echo "Remove report directories"
rm -rf /tmp/reports
rm -rf /tmp/junit

echo "Create reports directory"
mkdir -pv /tmp/reports

echo "Copy reports to reports directory"
cp "${SHARED_DIR}"/junit_*.xml /tmp/reports/ 2>/dev/null || echo "No report_*.xml files found"

echo "Create junit directory"
mkdir -pv /tmp/junit

echo "Copy junit reports to junit directory"
cp "${SHARED_DIR}"/junit_*.xml /tmp/junit/ 2>/dev/null || echo "No junit_*.xml files found"

echo "Upload compute-nto test reports"
cd /eco-ci-cd
# shellcheck disable=SC2154
ansible-playbook ./playbooks/cnf/upload-report.yaml -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig \
        reporter_template_name='${REPORTER_TEMPLATE_NAME}' processed_report_dir=/tmp/reports \
        junit_report_dir=/tmp/junit reports_directory=/tmp/upload"

echo "Compute-NTO reporting completed successfully" 