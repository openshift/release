#!/bin/bash
set -e
set -o pipefail

PYTHON_SCRIPT="clone-z-stream-issue.py"
SCRIPTS_FOLDER="/eco-ci-cd/scripts"
CLUSTER_VERSION_FILE="${SHARED_DIR}/cluster_version"
JIRA_TOKEN_FILE=/var/run/jira-token/token

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

if [[ ! -f "$CLUSTER_VERSION_FILE" ]]; then
  echo "Error: Cluster version file not found: '$CLUSTER_VERSION_FILE'." >&2
  exit 1
fi

if [[ ! -f "$JIRA_TOKEN_FILE" ]]; then
  echo "Error: Jira token file not found: '$JIRA_TOKEN_FILE'" >&2
  exit 1
fi

JIRA_TOKEN="$(cat $JIRA_TOKEN_FILE)"
Z_STREAM_VERSION="$(cat $CLUSTER_VERSION_FILE)"

if [[ -z "$JIRA_TOKEN" ]]; then
  echo "Error: JIRA_TOKEN file is empty: '$JIRA_TOKEN'." >&2
  exit 1
fi

if [[ -z "$Z_STREAM_VERSION" ]]; then
  echo "Error: Z stream version file is empty: '$Z_STREAM_VERSION'." >&2
  exit 1
fi

echo "Content of shared_dir is: $(ls -la $SHARED_DIR)"

echo "Running Z stream issue clone for compute-nto - version: $Z_STREAM_VERSION"

export JIRA_TOKEN
export Z_STREAM_VERSION
export SHARED_DIR
export TELCO_DOMAIN="compute-nto"

cd $SCRIPTS_FOLDER
python3 $PYTHON_SCRIPT 