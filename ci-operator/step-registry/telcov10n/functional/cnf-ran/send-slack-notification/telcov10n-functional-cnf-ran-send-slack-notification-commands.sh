#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

if [ "$JOB_TYPE" = "presubmit" ]; then
  echo "JOB_TYPE=presubmit — skipping"
  exit 0
fi

SCRIPTS_FOLDER="/eco-ci-cd/scripts/ran"
PYTHON_SCRIPT="send-ran-slack-notification.py"
WEBHOOK_URL_FILE=/var/run/slack-webhook-url/url

if [[ ! -f "$WEBHOOK_URL_FILE" ]]; then
  echo "Error: Webhook URL file not found: '$WEBHOOK_URL_FILE'" >&2
  exit 1
fi

WEBHOOK_URL="$(cat "$WEBHOOK_URL_FILE")"

JOB_NAME="${JOB_NAME:-unknown}"
BUILD_ID="${BUILD_ID:-unknown}"
JOB_URL="https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}"

if [[ -f "${SHARED_DIR}/cluster_version" ]]; then
  BUILD_VERSION="$(cat "${SHARED_DIR}/cluster_version")"
  echo "Build version: ${BUILD_VERSION}"
else
  echo "Error: cluster_version file not found: '${SHARED_DIR}/cluster_version'" >&2
  exit 1
fi

echo "Fetching bastion credentials for ${CLUSTER_NAME}"
BASTION_IP=$(cat /var/host_variables/${CLUSTER_NAME}/bastion/ansible_host)
BASTION_USER=$(cat /var/group_variables/common/all/ansible_user)

cat /var/group_variables/common/all/ansible_ssh_private_key > "/tmp/temp_ssh_key"
chmod 600 "/tmp/temp_ssh_key"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /tmp/temp_ssh_key"

echo "Collecting ReportPortal URLs"
REPORT_FLAGS=""
for REPORTPORTAL_FILE in ${REPORTPORTAL_FILES//;/ }; do
  REPORT_NAME="${REPORTPORTAL_FILE#.reportportal_url_}"
  REPORT_NAME="${REPORT_NAME//_/ }"

  if scp ${SSH_OPTS} \
      "${BASTION_USER}@${BASTION_IP}:/tmp/${REPORTPORTAL_FILE}" \
      "${SHARED_DIR}/${REPORTPORTAL_FILE}" 2>/dev/null; then

    if [[ -f "${SHARED_DIR}/${REPORTPORTAL_FILE}" ]] && [[ -s "${SHARED_DIR}/${REPORTPORTAL_FILE}" ]]; then
      REPORTPORTAL_FILE_CONTENT="$(cat "${SHARED_DIR}/${REPORTPORTAL_FILE}")"
      echo "ReportPortal ${REPORT_NAME} URL: ${REPORTPORTAL_FILE_CONTENT}"
      REPORT_FLAG=" --${REPORTPORTAL_FILE,,}"
      REPORT_FLAG="${REPORT_FLAG//_/-}"
      REPORT_FLAG="${REPORT_FLAG//--./--} ${REPORTPORTAL_FILE_CONTENT}"
      REPORT_FLAGS+=" ${REPORT_FLAG}"
    fi
  else
    echo "No ReportPortal ${REPORT_NAME} URL file found on bastion"
  fi
done

POLARION_URL="N/A"
if scp ${SSH_OPTS} "${BASTION_USER}@${BASTION_IP}:/tmp/.polarion_url" "${SHARED_DIR}/polarion_url" 2>/dev/null; then
  if [[ -f "${SHARED_DIR}/polarion_url" ]] && [[ -s "${SHARED_DIR}/polarion_url" ]]; then
    POLARION_URL="$(cat "${SHARED_DIR}/polarion_url")"
  fi
fi
echo "Polarion URL: ${POLARION_URL}"

echo "Sending Slack notification"
cd "$SCRIPTS_FOLDER"

python3 "$PYTHON_SCRIPT" \
  --webhook-url "$WEBHOOK_URL" \
  --build "$BUILD_VERSION" \
  --polarion-url "$POLARION_URL" \
  --job-url "$JOB_URL" \
  ${REPORT_FLAGS}

echo "Slack notification sent successfully"
