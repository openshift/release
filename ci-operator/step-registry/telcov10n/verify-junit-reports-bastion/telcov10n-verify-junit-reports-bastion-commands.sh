#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

echo "Failed" >> "${SHARED_DIR}/job_status.txt"

PROJECT_DIR="/tmp"

echo "Set bastion SSH configuration"
cat /var/group_variables/common/all/ansible_ssh_private_key > "${PROJECT_DIR}/temp_ssh_key"
chmod 600 "${PROJECT_DIR}/temp_ssh_key"
trap 'rm -f "${PROJECT_DIR}/temp_ssh_key"' EXIT

BASTION_HOST_FILE="/var/host_variables/${CLUSTER_NAME}/bastion/ansible_host"
if [[ -r "${BASTION_HOST_FILE}" ]]; then
  BASTION_IP=$(tr -d '[:space:]' < "${BASTION_HOST_FILE}")
else
  BASTION_IP=$(python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["ansible_host"])' < "${SHARED_DIR}/bastion")
fi
BASTION_USER=$(tr -d '[:space:]' < /var/group_variables/common/all/ansible_user)

REPORT_DIR="${JUNIT_REPORT_DIR}"
if [[ -s "${SHARED_DIR}/bastion_junit_report_dir" ]]; then
  REPORT_DIR=$(cat "${SHARED_DIR}/bastion_junit_report_dir")
fi

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${PROJECT_DIR}/temp_ssh_key")

echo "Copy fail_if_any_test_failed.py to bastion"
scp "${SSH_OPTS[@]}" \
  /eco-ci-cd/scripts/fail_if_any_test_failed.py \
  "${BASTION_USER}@${BASTION_IP}:/tmp/fail_if_any_test_failed.py"

echo "Run JUnit verification on bastion against ${REPORT_DIR}"
printf -v verifier_args ' %q' "${REPORT_DIR}" "${KNOWN_FAILURES:-[]}"
ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" "bash -s --${verifier_args}" <<'EOF'
  set -e
  python3 -m venv --clear /tmp/verify-junit-venv
  /tmp/verify-junit-venv/bin/pip install --quiet junitparser
  SHARED_DIR="$1" KNOWN_FAILURES="$2" \
    /tmp/verify-junit-venv/bin/python3 /tmp/fail_if_any_test_failed.py
EOF

echo "Passed" > "${SHARED_DIR}/job_status.txt"
