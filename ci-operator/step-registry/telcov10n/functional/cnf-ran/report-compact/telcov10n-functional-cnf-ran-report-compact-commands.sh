#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"
HUB_KUBECONFIG="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

process_inventory() {
  local directory="$1"
  local dest_file="$2"

  if [ -z "$directory" ]; then
    echo "Usage: process_inventory <directory> <dest_file>"
    return 1
  fi

  if [ ! -d "$directory" ]; then
    echo "Error: '$directory' is not a valid directory"
    return 1
  fi

  find "$directory" -type f | while IFS= read -r filename; do
    if [[ $filename == *"secretsync-vault-source-path"* ]]; then
      continue
    fi
    local content
    content=$(cat "$filename")
    local varname
    varname=$(basename "${filename}")
    if [[ "$content" == *$'\n'* ]]; then
      echo "${varname}: |"
      echo "$content" | sed 's/^/  /'
    else
      echo "${varname}": \'"${content}"\'
    fi
  done > "${dest_file}"
}

echo "Processing common group_vars"
mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/group_vars"

find /var/group_variables/common/ -mindepth 1 -type d 2>/dev/null | while read -r dir; do
  echo "  group_var: $(basename "${dir}")"
  process_inventory "$dir" "${ECO_CI_CD_INVENTORY_PATH}/group_vars/$(basename "${dir}")"
done

echo "Processing hub host_vars (${CLUSTER_NAME})"
mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/host_vars"

find "/var/host_variables/${CLUSTER_NAME}/" -mindepth 1 -type d 2>/dev/null | while read -r dir; do
  echo "  host_var: $(basename "${dir}")"
  process_inventory "$dir" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/$(basename "${dir}")"
done

rm -rf /tmp/reports /tmp/junit

mkdir -p /tmp/reports
for f in "${SHARED_DIR}"/polarion_*.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f" | sed 's/^polarion_//')
    cp "$f" "/tmp/reports/${filename}"
  fi
done

mkdir -p /tmp/junit
for f in "${SHARED_DIR}"/junit_*.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f" | sed 's/^junit_//')
    cp "$f" "/tmp/junit/${filename}"
  fi
done

cd /eco-ci-cd

SPOKE_KUBECONFIG="/tmp/${SPOKE_CLUSTER}-kubeconfig"
CI_LANE="${REPORTER_TEMPLATE_NAME%-*.*}"
METRICS_FILE="/tmp/metrics/ran-metrics.txt"

echo "Collecting metrics"
ansible-playbook ./playbooks/ran/collect-metrics.yml \
  -i ./inventories/cnf/switch-config.yaml \
  --extra-vars "ran_hub_kubeconfig=${HUB_KUBECONFIG} \
    ran_spoke_kubeconfig=${SPOKE_KUBECONFIG} \
    ran_ci_lane='${CI_LANE}' \
    ran_output_file=${METRICS_FILE} \
    ran_metrics_list=${RAN_METRICS_LIST}" || true

REPORTS_PORTAL_ATTRIBUTES=""
if [[ -f "${METRICS_FILE}" ]]; then
  REPORTS_PORTAL_ATTRIBUTES="$(cat "${METRICS_FILE}")"
  echo "REPORTS_PORTAL_ATTRIBUTES: ${REPORTS_PORTAL_ATTRIBUTES}"
fi

echo "Uploading reports to Polarion and Report Portal"
ansible-playbook ./playbooks/upload-report.yaml \
  -i ./inventories/cnf/switch-config.yaml \
  --extra-vars "kubeconfig=${HUB_KUBECONFIG} \
    reporter_template_name='${REPORTER_TEMPLATE_NAME}' \
    processed_report_dir=/tmp/reports \
    junit_report_dir=/tmp/junit \
    reports_directory=/tmp/upload \
    upload_to_report_portal=${UPLOAD_TO_REPORT_PORTAL} \
    report_portal_url_filename='${REPORTPORTAL_FILES}' \
    reports_portal_attributes='${REPORTS_PORTAL_ATTRIBUTES}'"
