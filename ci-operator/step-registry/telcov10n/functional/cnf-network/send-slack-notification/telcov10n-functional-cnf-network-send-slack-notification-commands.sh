#!/bin/bash
set -e
set -o pipefail

SCRIPTS_FOLDER="/eco-ci-cd/scripts"
PYTHON_SCRIPT="send-slack-notification-bot.py"
CLUSTER_VERSION_FILE="${SHARED_DIR}/cluster_version"
WEBHOOK_URL_FILE=/var/run/slack-webhook-url/url
CLUSTER_NAME_FILE="${SHARED_DIR}/cluster_name"
NIC_FILE="${SHARED_DIR}/ocp_nic"
SECONDARY_NIC_FILE="${SHARED_DIR}/secondary_nic"
JIRA_LINK_FILE="${SHARED_DIR}/jira_link"

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi


BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${SHARED_DIR}/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${SHARED_DIR}/all" | sed "s/'//g")

echo "Set bastion ssh configuration"
grep ansible_ssh_private_key -A 100 "${SHARED_DIR}/all" | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > "/tmp/temp_ssh_key"

chmod 600 "/tmp/temp_ssh_key"
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /tmp/temp_ssh_key "${BASTION_USER}@${BASTION_IP}":/tmp/.polarion_url "${SHARED_DIR}/polarion_url"


if [[ ! -f "$CLUSTER_VERSION_FILE" ]]; then
  echo "Error: Cluster version file not found: '$CLUSTER_VERSION_FILE'." >&2
  exit 1
fi

if [[ ! -f "$WEBHOOK_URL_FILE" ]]; then
  echo "Error: Webhook URL file not found: '$WEBHOOK_URL_FILE'" >&2
  exit 1
fi

if [[ -z "$CLUSTER_NAME_FILE" ]]; then
  echo "Error: Cluster name file is empty: '$CLUSTER_NAME_FILE'." >&2
  exit 1
fi

if [[ -z "$NIC_FILE" ]]; then
  echo "Error: NIC file is empty: '$NIC_FILE'." >&2
  exit 1
fi

if [[ -z "$SECONDARY_NIC_FILE" ]]; then
  echo "Error: Secondary NIC file is empty: '$SECONDARY_NIC_FILE'." >&2
  exit 1
fi

# Read polarion URL if available
POLARION_URL=""
if [[ -f "${SHARED_DIR}/polarion_url" ]] && [[ -s "${SHARED_DIR}/polarion_url" ]]; then
  POLARION_URL="$(cat ${SHARED_DIR}/polarion_url)"
  echo "Polarion URL: ${POLARION_URL}"
else
  echo "No polarion URL file found or file is empty"
fi

WEBHOOK_URL="$(cat $WEBHOOK_URL_FILE)"
Z_STREAM_VERSION="$(cat $CLUSTER_VERSION_FILE)"
CLUSTER_NAME="$(cat $CLUSTER_NAME_FILE)"
NIC="$(cat $NIC_FILE)"
SECONDARY_NIC="$(cat $SECONDARY_NIC_FILE)"
JIRA_LINK="$(cat $JIRA_LINK_FILE)"

echo "Sending Slack notification to cnf-qe-core channel..."
cd $SCRIPTS_FOLDER
python3 $PYTHON_SCRIPT \
  --webhook-url "$WEBHOOK_URL" \
  --version "$Z_STREAM_VERSION" \
  --polarion-url "$POLARION_URL" \
  --cluster-name "$CLUSTER_NAME" \
  --nic "$NIC" \
  --secondary-nic "$SECONDARY_NIC" \
  --jira-link "$JIRA_LINK"



