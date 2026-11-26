#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
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

CI_LANE="${REPORTER_LAUNCH_NAME}"
BASTION_JUNIT_DIR_FILE="${SHARED_DIR}/bastion_junit_report_dir"
if [[ -s "${BASTION_JUNIT_DIR_FILE}" ]]; then
  REPORT_DIR=$(cat "${BASTION_JUNIT_DIR_FILE}")
  UPLOAD_SHARED_DIR=""
  LEGACY_JUNIT_ARG=""
  # Keep the metrics lane stable across versioned RAN launches.
  CI_LANE="${REPORTER_LAUNCH_NAME%-[0-9]*.[0-9]*}"
elif ! compgen -G "${SHARED_DIR}/*polarion*.xml" > /dev/null 2>&1; then
  echo "No Reports found in ${SHARED_DIR}, Using Bastion"
  REPORT_DIR="/tmp/test_reports/polarion"
  LEGACY_JUNIT_ARG="junit_report_dir=/tmp/test_reports/junit"
  UPLOAD_SHARED_DIR=""
else
  echo "Reports found in SHARED_DIR"
  rm -rf /tmp/reports /tmp/junit
  mkdir -pv /tmp/reports /tmp/junit
  for f in "${SHARED_DIR}"/*polarion*.xml; do
    if [[ -f "$f" ]]; then
      filename=$(basename "$f" | sed 's/^polarion_//')
      cp "$f" "/tmp/reports/${filename}"
    fi
  done

  for f in "${SHARED_DIR}"/report_*.xml; do
    if [[ -f "$f" ]]; then
      filename=$(basename "$f" | sed 's/^report_//')
      cp "$f" "/tmp/reports/${filename}"
    fi
  done

  for f in "${SHARED_DIR}"/junit_*.xml; do
    if [[ -f "$f" ]]; then
      filename=$(basename "$f" | sed 's/^junit_//')
      cp "$f" "/tmp/junit/${filename}"
    fi
  done
  REPORT_DIR=/tmp/reports
  LEGACY_JUNIT_ARG="junit_report_dir=/tmp/junit"
  UPLOAD_SHARED_DIR="${SHARED_DIR}"
fi

cd "${ECO_CI_CD_DIR}"

METRICS_FILE="/tmp/metrics/metrics.txt"

echo "Collecting metrics"
ansible-playbook ./playbooks/collect-metrics.yml \
  -i ./inventories/cnf/switch-config.yaml \
  --extra-vars "kubeconfig=${KUBECONFIG} \
    ci_lane='${CI_LANE}' \
    output_file=${METRICS_FILE} \
    metrics_list=${METRICS_LIST}" || true

REPORTS_PORTAL_ATTRIBUTES=""
if [[ -f "${METRICS_FILE}" ]]; then
  REPORTS_PORTAL_ATTRIBUTES="$(cat "${METRICS_FILE}")"
  echo "REPORTS_PORTAL_ATTRIBUTES: ${REPORTS_PORTAL_ATTRIBUTES}"
fi

echo "Uploading reports from ${REPORT_DIR}"
SHARED_DIR="${UPLOAD_SHARED_DIR}" ansible-playbook ./playbooks/upload-report.yaml \
  -i ./inventories/cnf/switch-config.yaml \
  --extra-vars "kubeconfig=${KUBECONFIG} \
    reporter_template_name='${REPORTER_TEMPLATE_NAME}' \
    processed_report_dir='${REPORT_DIR}' \
    ${LEGACY_JUNIT_ARG} \
    reports_directory=/tmp/upload \
    reporter_launch_name='${REPORTER_LAUNCH_NAME}' \
    upload_to_report_portal=${UPLOAD_TO_REPORT_PORTAL} \
    report_portal_url_filename='${REPORTPORTAL_FILES}' \
    reports_portal_attributes='${REPORTS_PORTAL_ATTRIBUTES}'"

if [[ -s "${BASTION_JUNIT_DIR_FILE}" ]]; then
  case "${UPLOAD_TO_REPORT_PORTAL,,}" in
    true|yes|on|1) touch "${SHARED_DIR}/report_portal_uploaded" ;;
  esac
fi
