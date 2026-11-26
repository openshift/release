#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

ECO_CI_CD_DIR=/eco-ci-cd
if [[ -n "${ECO_CI_CD_FORK_REPO:-}" ]]; then
  ECO_CI_CD_FORK_DIR=$(mktemp -d /tmp/eco-ci-cd-fork.XXXXXXXX)
  ECO_CI_CD_DIR="${ECO_CI_CD_FORK_DIR}"
  trap 'rm -rf "${ECO_CI_CD_FORK_DIR}"' EXIT
  git clone --depth 1 --branch "${ECO_CI_CD_FORK_BRANCH:-main}" -- \
    "${ECO_CI_CD_FORK_REPO}" "${ECO_CI_CD_DIR}"
  # Use the Ansible collections installed in the step image.
  export ANSIBLE_COLLECTIONS_PATH=/eco-ci-cd/collections
fi
ECO_CI_CD_INVENTORY_PATH="${ECO_CI_CD_DIR}/inventories/cnf"
HUB_KUBECONFIG="/home/telcov10n/project/generated/${TARGET_CLUSTER_NAME}/auth/kubeconfig"

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

echo "Processing hub host_vars (${TARGET_CLUSTER_NAME})"
mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/host_vars"

find "/var/host_variables/${TARGET_CLUSTER_NAME}/" -mindepth 1 -type d 2>/dev/null | while read -r dir; do
  echo "  host_var: $(basename "${dir}")"
  process_inventory "$dir" "${ECO_CI_CD_INVENTORY_PATH}/host_vars/$(basename "${dir}")"
done

rm -rf /tmp/reports

mkdir -p /tmp/reports
# The IBU test steps stage their suite JUnit XMLs as junit_ibu_seed_* and
# junit_ibu_upgrade_*; those files are the single Report Portal report set.
for f in "${SHARED_DIR}"/junit_*.xml; do
  if [[ -f "$f" ]]; then
    filename=$(basename "$f" | sed 's/^junit_//')
    cp "$f" "/tmp/reports/${filename}"
  fi
done

cd "${ECO_CI_CD_DIR}"

# Launches are version-qualified so different OCP versions do not collide in
# Report Portal, but the metrics ci_lane attribute must stay versionless.
CI_LANE="${REPORTER_LAUNCH_NAME%-[0-9]*.[0-9]*}"

METRICS_FILE="/tmp/metrics/ran-metrics.txt"

echo "Collecting metrics"
ansible-playbook ./playbooks/collect-metrics.yml \
  -i ./inventories/cnf/switch-config.yaml \
  --extra-vars "kubeconfig=${HUB_KUBECONFIG} \
    ci_lane='${CI_LANE}' \
    output_file=${METRICS_FILE} \
    metrics_list=${RAN_METRICS_LIST}" || true

REPORTS_PORTAL_ATTRIBUTES=""
if [[ -f "${METRICS_FILE}" ]]; then
  REPORTS_PORTAL_ATTRIBUTES="$(cat "${METRICS_FILE}")"
  echo "REPORTS_PORTAL_ATTRIBUTES: ${REPORTS_PORTAL_ATTRIBUTES}"
fi

echo "Uploading reports from /tmp/reports to Report Portal"
ansible-playbook ./playbooks/upload-report.yaml \
  -i ./inventories/cnf/switch-config.yaml \
  --extra-vars "kubeconfig=${HUB_KUBECONFIG} \
    reporter_template_name='${REPORTER_TEMPLATE_NAME}' \
    processed_report_dir=/tmp/reports \
    reports_directory=/tmp/upload \
    reporter_launch_name='${REPORTER_LAUNCH_NAME}' \
    upload_to_report_portal=${UPLOAD_TO_REPORT_PORTAL} \
    report_portal_url_filename='${REPORTPORTAL_FILES}' \
    reports_portal_attributes='${REPORTS_PORTAL_ATTRIBUTES}'"
