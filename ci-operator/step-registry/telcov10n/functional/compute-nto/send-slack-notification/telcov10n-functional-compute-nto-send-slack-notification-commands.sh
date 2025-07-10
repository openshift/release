#!/bin/bash
set -e
set -o pipefail

SCRIPTS_FOLDER="/eco-ci-cd/scripts"
PYTHON_SCRIPT="send-slack-notification-bot.py"
CLUSTER_VERSION_FILE="${SHARED_DIR}/cluster_version"
WEBHOOK_URL_FILE=/var/run/slack-webhook-url/url
CLUSTER_NAME_FILE="${SHARED_DIR}/cluster_name"
JIRA_LINK_FILE="${SHARED_DIR}/jira_link"

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

# Get bastion information if available
BASTION_IP=""
BASTION_USER=""
if [[ -f "${SHARED_DIR}/bastion" ]] && [[ -f "${SHARED_DIR}/all" ]]; then
    BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${SHARED_DIR}/bastion" | sed "s/'//g" || echo "")
    BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${SHARED_DIR}/all" | sed "s/'//g" || echo "")
    
    if [[ -n "$BASTION_IP" ]] && [[ -n "$BASTION_USER" ]]; then
        echo "Set bastion ssh configuration"
        grep ansible_ssh_private_key -A 100 "${SHARED_DIR}/all" | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > "/tmp/temp_ssh_key"
        chmod 600 "/tmp/temp_ssh_key"
        
        # Try to get polarion URL from bastion
        scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /tmp/temp_ssh_key "${BASTION_USER}@${BASTION_IP}":/tmp/.polarion_url "${SHARED_DIR}/polarion_url" 2>/dev/null || echo "No polarion URL available from bastion"
    fi
fi

if [[ ! -f "$CLUSTER_VERSION_FILE" ]]; then
  echo "Error: Cluster version file not found: '$CLUSTER_VERSION_FILE'." >&2
  exit 1
fi

if [[ ! -f "$WEBHOOK_URL_FILE" ]]; then
  echo "Error: Webhook URL file not found: '$WEBHOOK_URL_FILE'" >&2
  exit 1
fi

if [[ ! -f "$CLUSTER_NAME_FILE" ]]; then
  echo "Warning: Cluster name file not found: '$CLUSTER_NAME_FILE'. Using default." >&2
  echo "unknown-cluster" > "$CLUSTER_NAME_FILE"
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
JIRA_LINK=""
if [[ -f "$JIRA_LINK_FILE" ]]; then
    JIRA_LINK="$(cat $JIRA_LINK_FILE)"
fi

echo "Sending Slack notification for compute-nto..."
cd $SCRIPTS_FOLDER

# Build arguments for compute-nto domain
ARGS=(
  --webhook-url "$WEBHOOK_URL"
  --version "$Z_STREAM_VERSION"
  --cluster-name "$CLUSTER_NAME"
)

if [[ -n "$POLARION_URL" ]]; then
    ARGS+=(--polarion-url "$POLARION_URL")
fi

if [[ -n "$JIRA_LINK" ]]; then
    ARGS+=(--jira-link "$JIRA_LINK")
fi

python3 $PYTHON_SCRIPT "${ARGS[@]}" 