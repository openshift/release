#!/bin/bash
# shellcheck disable=SC2155

set -o errexit
set -o nounset
set -o pipefail

echo "************ assisted aws cleanup command ************"

AWS_ACCESS_KEY_FILE="${CLUSTER_PROFILE_DIR}/aws-access-key"
AWS_SECRET_KEY_FILE="${CLUSTER_PROFILE_DIR}/aws-secret-access-key"
SLACK_TOKEN_FILE="${CLUSTER_PROFILE_DIR}/slack-token"

if [ ! -f "${AWS_ACCESS_KEY_FILE}" ]; then
  echo "Error: AWS Access Key file not found at ${AWS_ACCESS_KEY_FILE}"
  exit 1
fi
export AWS_ACCESS_KEY_ID=$(cat "${AWS_ACCESS_KEY_FILE}")

if [ ! -f "${AWS_SECRET_KEY_FILE}" ]; then
  echo "Error: AWS Secret Access Key file not found at ${AWS_SECRET_KEY_FILE}"
  exit 1
fi
export AWS_SECRET_ACCESS_KEY=$(cat "${AWS_SECRET_KEY_FILE}")

if [ ! -f "${SLACK_TOKEN_FILE}" ]; then
  echo "Error: Slack Token file not found at ${SLACK_TOKEN_FILE}"
  exit 1
fi
export SLACK_TOKEN=$(cat "${SLACK_TOKEN_FILE}")

cd "${ANSIBLE_PLAYBOOK_DIRECTORY}"
ansible-playbook "${ANSIBLE_CLEANUP_PLAYBOOK}" -vv
