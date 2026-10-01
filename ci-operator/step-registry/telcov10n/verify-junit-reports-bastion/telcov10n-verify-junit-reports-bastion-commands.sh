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

BASTION_IP=$(tr -d '[:space:]' < "/var/host_variables/${CLUSTER_NAME}/bastion/ansible_host")
BASTION_USER=$(tr -d '[:space:]' < /var/group_variables/common/all/ansible_user)

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${PROJECT_DIR}/temp_ssh_key")

echo "Copy fail_if_any_test_failed.py to bastion"
scp "${SSH_OPTS[@]}" \
  /eco-ci-cd/scripts/fail_if_any_test_failed.py \
  "${BASTION_USER}@${BASTION_IP}:/tmp/fail_if_any_test_failed.py"

echo "Run JUnit verification on bastion against ${JUNIT_REPORT_DIR}"
# shellcheck disable=SC2087
ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" bash <<EOF
  set -e
  python3 -m venv --clear /tmp/verify-junit-venv
  /tmp/verify-junit-venv/bin/pip install --quiet junitparser
  SHARED_DIR=${JUNIT_REPORT_DIR} KNOWN_FAILURES='${KNOWN_FAILURES:-[]}' \
    /tmp/verify-junit-venv/bin/python3 /tmp/fail_if_any_test_failed.py
EOF

echo "Passed" > "${SHARED_DIR}/job_status.txt"
