#!/bin/bash
set -e
set -o pipefail

SCRIPTS_FOLDER="/eco-ci-cd/scripts"
PYTHON_SCRIPT="send-slack-notification-bot.py"
CLUSTER_VERSION_FILE="${SHARED_DIR}/cluster_version"
WEBHOOK_URL_FILE=/var/run/slack-webhook-url/url

if [[ ! -f "$CLUSTER_VERSION_FILE" ]]; then
  echo "Error: Cluster version file not found: '$CLUSTER_VERSION_FILE'." >&2
  exit 1
fi

if [[ ! -f "$WEBHOOK_URL_FILE" ]]; then
  echo "Error: Webhook URL file not found: '$WEBHOOK_URL_FILE'" >&2
  exit 1
fi


WEBHOOK_URL="$(cat $WEBHOOK_URL_FILE)"
Z_STREAM_VERSION="$(cat $CLUSTER_VERSION_FILE)"

if [[ -z "$WEBHOOK_URL" ]]; then
  echo "Error: webhook url file is empty: '$WEBHOOK_URL'." >&2
  exit 1
fi

if [[ -z "$Z_STREAM_VERSION" ]]; then
  echo "Error: Cluster version file is empty: '$CLUSTER_VERSION_FILE'." >&2
  exit 1
fi

export WEBHOOK_URL
export Z_STREAM_VERSION
export SHARED_DIR
export JOB_URL

echo "Sending Slack notification to cnf-qe-core channel..."
cd $SCRIPTS_FOLDER
python3 $PYTHON_SCRIPT

