#!/bin/bash
set -e
set -o pipefail

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
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

KUBECONFIG="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

echo "Remove report directories"
rm -rf /tmp/reports /tmp/junit

echo "Create reports directory"
mkdir -pv /tmp/reports

for f in "${SHARED_DIR}"/polarion_*.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f" | sed 's/^polarion_//')
    cp "$f" "/tmp/reports/${filename}"
  fi
done

echo "Create junit directory"
mkdir -pv /tmp/junit

echo "Copy junit reports to junit directory"
for f in "${SHARED_DIR}"/junit_*.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f" | sed 's/^junit_//')
    cp "$f" "/tmp/junit/${filename}"
  fi
done

cd /eco-ci-cd

METRICS_FILE="/tmp/metrics/metrics.txt"

echo "Collecting metrics"
ansible-playbook ./playbooks/collect-metrics.yml \
  -i ./inventories/cnf/switch-config.yaml \
  --extra-vars "kubeconfig=${HUB_KUBECONFIG} \
    ci_lane='${REPORTER_LAUNCH_NAME}' \
    output_file=${METRICS_FILE} \
    metrics_list=${METRICS_LIST}" || true

REPORTS_PORTAL_ATTRIBUTES=""
if [[ -f "${METRICS_FILE}" ]]; then
  REPORTS_PORTAL_ATTRIBUTES="$(cat "${METRICS_FILE}")"
  echo "REPORTS_PORTAL_ATTRIBUTES: ${REPORTS_PORTAL_ATTRIBUTES}"
fi

echo "Uploading reports to Polarion and Report Portal"
ansible-playbook ./playbooks/upload-report.yaml \
  -i ./inventories/cnf/switch-config.yaml \
  --extra-vars "kubeconfig=${KUBECONFIG} \
    reporter_template_name='${REPORTER_TEMPLATE_NAME}' \
    processed_report_dir=/tmp/reports \
    junit_report_dir=/tmp/junit \
    reports_directory=/tmp/upload \
    reporter_launch_name='${REPORTER_LAUNCH_NAME}' \
    upload_to_report_portal=${UPLOAD_TO_REPORT_PORTAL} \
    report_portal_url_filename='${REPORTPORTAL_FILES}' \
    reports_portal_attributes='${REPORTS_PORTAL_ATTRIBUTES}'"
