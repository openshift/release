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
  "${ECO_CI_CD}/scripts/fail_if_any_test_failed.py" \
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
