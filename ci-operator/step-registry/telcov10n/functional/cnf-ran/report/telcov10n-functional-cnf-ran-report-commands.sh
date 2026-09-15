#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

ECO_CI_CD_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"
HUB_KUBECONFIG="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

COMMON_VARIABLES="/var/common_variables"

install_vars() {
  local src="$1"
  local allow_host_vars="$2"
  local base dest_dir name

  base="$(basename "$src")"

  case "$base" in
    ansible_group_*)
      dest_dir="${ECO_CI_CD_INVENTORY_PATH}/group_vars"
      name="${base#ansible_group_}"
      ;;
    *)
      if [ "${allow_host_vars}" != "true" ]; then
        echo "  skipped a file that is not a group var"
        return 0
      fi
      dest_dir="${ECO_CI_CD_INVENTORY_PATH}/host_vars"
      case "$base" in
        bastion*) name="bastion" ;;
        *)        name="${base}" ;;
      esac
      ;;
  esac
  cp "$src" "${dest_dir}/${name}"
}

process_mount() {
  local directory="$1"
  local allow_host_vars="$2"

  if [ ! -d "$directory" ]; then
    echo "Error: '$directory' is not a valid directory"
    return 1
  fi

  # -L so that files exposed as symlinks by the secrets mount are matched as regular files
  while IFS= read -r filename; do
    install_vars "$filename" "${allow_host_vars}"
  done < <(find -L "$directory" -maxdepth 1 -type f ! -name '..*' | sort)
}

echo "Create inventory directories"
mkdir -p "${ECO_CI_CD_INVENTORY_PATH}/group_vars" "${ECO_CI_CD_INVENTORY_PATH}/host_vars"

echo "Processing common group_vars"
process_mount "${COMMON_VARIABLES}" false

echo "Processing hub host_vars (${CLUSTER_NAME})"
process_mount "/var/clusters/${CLUSTER_NAME}" true

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

METRICS_FILE="/tmp/metrics/ran-metrics.txt"

echo "Collecting metrics"
ansible-playbook ./playbooks/collect-metrics.yml \
  -i ./inventories/cnf/switch-config.yaml \
  --extra-vars "kubeconfig=${HUB_KUBECONFIG} \
    ci_lane='${REPORTER_LAUNCH_NAME}' \
    output_file=${METRICS_FILE} \
    metrics_list=${RAN_METRICS_LIST}" || true

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
    reporter_launch_name='${REPORTER_LAUNCH_NAME}' \
    upload_to_report_portal=${UPLOAD_TO_REPORT_PORTAL} \
    report_portal_url_filename='${REPORTPORTAL_FILES}' \
    reports_portal_attributes='${REPORTS_PORTAL_ATTRIBUTES}'"
