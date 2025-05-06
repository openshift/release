#!/bin/bash
set -e
set -o pipefail

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"

echo "Create group_vars directory"
mkdir "${ECO_CI_CD_INVENTORY_PATH}/group_vars"

echo "Copy group inventory files"
# shellcheck disable=SC2154
cp "${SHARED_DIR}/all" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/all"
cp "${SHARED_DIR}/bastions" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/bastions"

echo "Create host_vars directory"
mkdir "${ECO_CI_CD_INVENTORY_PATH}/host_vars"

echo "Copy host inventory files"
cp "${SHARED_DIR}/bastion" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/bastion"

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi

export CLUSTER_NAME="${CLUSTER_NAME}"
echo CLUSTER_NAME="${CLUSTER_NAME}"

echo "Remove report directories"
rm -rf /tmp/reports
rm -rf /tmp/junit

echo "Create reports directory"
mkdir /tmp/reports

echo "Copy reports to reports directory"
cp "${SHARED_DIR}"/report_*.xml /tmp/reports/ 2>/dev/null

echo "Create junit directory"
mkdir /tmp/junit

echo "Copy report to junit directory"
cp "${SHARED_DIR}"/junit_*.xml /tmp/junit/ 2>/dev/null

echo "Upload reports"
cd /eco-ci-cd
# shellcheck disable=SC2154
ansible-playbook ./playbooks/cnf/upload-report.yaml -i ./inventories/cnf/switch-config.yaml \
    --extra-vars "kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig \
        reporter_template_name='${REPORTER_TEMPLATE_NAME}' processed_report_dir=/tmp/reports \
        junit_report_dir=/tmp/junit reports_directory=/tmp/upload"
