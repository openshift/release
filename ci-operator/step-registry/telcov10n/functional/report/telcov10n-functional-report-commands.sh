#!/bin/bash
set -e
set -o pipefail

# eco-ci-cd checkout used by this step: the content baked into the step image,
# or a shallow clone of ECO_CI_CD_FORK_REPO@ECO_CI_CD_FORK_BRANCH when the
# fork override is set (rehearsal-only knob provided by the lane's ci-operator
# config; the clone lives in /tmp because /eco-ci-cd is not writable by the
# step's runtime user).
ECO_CI_CD="/eco-ci-cd"
if [[ -n "${ECO_CI_CD_FORK_REPO:-}" ]]; then
  ECO_CI_CD_FORK_BRANCH="${ECO_CI_CD_FORK_BRANCH:-main}"
  ECO_CI_CD="/tmp/eco-ci-cd-fork"
  echo "Using eco-ci-cd fork ${ECO_CI_CD_FORK_REPO}@${ECO_CI_CD_FORK_BRANCH}"
  git clone --depth 1 --branch "${ECO_CI_CD_FORK_BRANCH}" \
    "${ECO_CI_CD_FORK_REPO}" "${ECO_CI_CD}"
  # collections/ is not tracked in git (it only exists in the step image,
  # installed at /eco-ci-cd/collections by ansible-galaxy during the image
  # build), so the clone lacks it. Copy the image's collections over so
  # ansible.cfg's ./collections resolves inside the fork checkout as well.
  mkdir -p "${ECO_CI_CD}/collections"
  cp -R --no-preserve=ownership /eco-ci-cd/collections/. "${ECO_CI_CD}/collections/"
fi

ECO_CI_CD_INVENTORY_PATH="${ECO_CI_CD}/inventories/cnf"

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

echo "Create junit directory"
mkdir -pv /tmp/junit

if ! compgen -G "${SHARED_DIR}/*polarion*.xml" > /dev/null 2>&1; then
  echo "No Reports found in ${SHARED_DIR}, Using Bastion"
  BASTION_REPORT_DIR="/tmp/test_reports"
  POLARION_REPORT_DIR="${BASTION_REPORT_DIR}/polarion"
  JUNIT_REPORT_DIR="${BASTION_REPORT_DIR}/junit"
  UPLOAD_SHARED_DIR=""
else
  echo "Reports found in SHARED_DIR"
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
  POLARION_REPORT_DIR=/tmp/reports
  JUNIT_REPORT_DIR=/tmp/junit
  UPLOAD_SHARED_DIR="${SHARED_DIR}"
fi

cd "${ECO_CI_CD}"

METRICS_FILE="/tmp/metrics/metrics.txt"

echo "Collecting metrics"
ansible-playbook ./playbooks/collect-metrics.yml \
  -i ./inventories/cnf/switch-config.yaml \
  --extra-vars "kubeconfig=${KUBECONFIG} \
    ci_lane='${REPORTER_LAUNCH_NAME}' \
    output_file=${METRICS_FILE} \
    metrics_list=${METRICS_LIST}" || true

REPORTS_PORTAL_ATTRIBUTES=""
if [[ -f "${METRICS_FILE}" ]]; then
  REPORTS_PORTAL_ATTRIBUTES="$(cat "${METRICS_FILE}")"
  echo "REPORTS_PORTAL_ATTRIBUTES: ${REPORTS_PORTAL_ATTRIBUTES}"
fi

echo "Uploading reports to Polarion and Report Portal"
SHARED_DIR="${UPLOAD_SHARED_DIR}" ansible-playbook ./playbooks/upload-report.yaml \
  -i ./inventories/cnf/switch-config.yaml \
  --extra-vars "kubeconfig=${KUBECONFIG} \
    reporter_template_name='${REPORTER_TEMPLATE_NAME}' \
    processed_report_dir=${POLARION_REPORT_DIR} \
    junit_report_dir=${JUNIT_REPORT_DIR} \
    reports_directory=/tmp/upload \
    reporter_launch_name='${REPORTER_LAUNCH_NAME}' \
    upload_to_report_portal=${UPLOAD_TO_REPORT_PORTAL} \
    report_portal_url_filename='${REPORTPORTAL_FILES}' \
    reports_portal_attributes='${REPORTS_PORTAL_ATTRIBUTES}'"
