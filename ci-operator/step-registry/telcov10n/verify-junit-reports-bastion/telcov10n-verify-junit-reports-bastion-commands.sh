#!/bin/bash
# Disable tracing because this step handles the bastion SSH key.
set +x
umask 077
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

echo "Failed" >> "${SHARED_DIR}/job_status.txt"

# Keep execution/collection failures even when the available XML reports pass.
result=0
read -r -a required_results <<< "${JUNIT_REQUIRED_RESULT_FILES:-}"
for name in "${required_results[@]}"; do
  if [[ ! "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "Invalid required result filename." >&2
    result=1
    continue
  fi
  result_file="${SHARED_DIR}/${name}"
  if [[ ! -r "${result_file}" ]]; then
    echo "Missing required result: ${name}." >&2
    result=1
    continue
  fi
  status=$(<"${result_file}")
  if [[ ! "${status}" =~ ^(0|[1-9][0-9]{0,2})$ ]] || (( status > 255 )); then
    echo "Invalid exit code in ${name}." >&2
    result=1
  elif (( status != 0 )); then
    echo "${name} recorded exit code ${status}; the job will fail." >&2
    result=1
  fi
done

if [[ -n "${JUNIT_REPORT_DIR_FILE:-}" ]]; then
  if [[ ! "${JUNIT_REPORT_DIR_FILE}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "Invalid report-directory filename." >&2
    exit 1
  fi
  report_dir_file="${SHARED_DIR}/${JUNIT_REPORT_DIR_FILE}"
  if [[ ! -r "${report_dir_file}" ]]; then
    echo "Missing current-run report directory file." >&2
    exit 1
  fi
  JUNIT_REPORT_DIR=$(<"${report_dir_file}")
  if [[ "${JUNIT_REPORT_DIR}" != /* || "${JUNIT_REPORT_DIR}" == *$'\n'* ]]; then
    echo "The current-run report directory must be one absolute path." >&2
    exit 1
  fi
fi

PROJECT_DIR="/tmp"

echo "Set bastion SSH configuration"
cat /var/group_variables/common/all/ansible_ssh_private_key > "${PROJECT_DIR}/temp_ssh_key"
chmod 600 "${PROJECT_DIR}/temp_ssh_key"
trap 'rm -f "${PROJECT_DIR}/temp_ssh_key"' EXIT

if [[ -n "${JUNIT_INVENTORY_PREFIX:-}" ]]; then
  if [[ ! "${JUNIT_INVENTORY_PREFIX}" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Invalid shared inventory prefix." >&2
    exit 1
  fi
  BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' \
    "${SHARED_DIR}/${JUNIT_INVENTORY_PREFIX}bastion" | sed "s/'//g")
  BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' \
    "${SHARED_DIR}/${JUNIT_INVENTORY_PREFIX}all" | sed "s/'//g")
else
  BASTION_IP=$(tr -d '[:space:]' < "/var/host_variables/${CLUSTER_NAME}/bastion/ansible_host")
  BASTION_USER=$(tr -d '[:space:]' < /var/group_variables/common/all/ansible_user)
fi
[[ -n "${BASTION_IP}" && -n "${BASTION_USER}" ]]

redact_bastion() {
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line//${BASTION_USER}@${BASTION_IP}/<bastion>}"
    line="${line//${BASTION_IP}/<bastion>}"
    printf '%s\n' "${line}"
  done
}

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "${PROJECT_DIR}/temp_ssh_key")

echo "Copy fail_if_any_test_failed.py to bastion"
scp "${SSH_OPTS[@]}" \
  /eco-ci-cd/scripts/fail_if_any_test_failed.py \
  "${BASTION_USER}@${BASTION_IP}:/tmp/fail_if_any_test_failed.py" \
  2>&1 | redact_bastion

echo "Run JUnit verification on bastion against ${JUNIT_REPORT_DIR}"
# Quote values for the remote Bash command, including JSON with apostrophes.
printf -v remote_report_dir '%q' "${JUNIT_REPORT_DIR}"
printf -v remote_known_failures '%q' "${KNOWN_FAILURES:-[]}"
set +e
# shellcheck disable=SC2087
ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" bash <<EOF 2>&1 | redact_bastion
  set -e
  python3 -m venv --clear /tmp/verify-junit-venv
  /tmp/verify-junit-venv/bin/pip install --quiet junitparser
  TESTS_DIR=${remote_report_dir} SHARED_DIR=${remote_report_dir} \
    KNOWN_FAILURES=${remote_known_failures} \
    /tmp/verify-junit-venv/bin/python3 /tmp/fail_if_any_test_failed.py
EOF
verify_rc=$?
set -e
if (( verify_rc != 0 )); then
  result=1
fi

if (( result != 0 )); then
  echo "JUnit verification or a required execution result failed." >&2
  exit 1
fi
echo "Passed" > "${SHARED_DIR}/job_status.txt"
