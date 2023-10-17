#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

CLUSTER_PROFILE_DIR="/run/secrets/ci.openshift.io/cluster-profile"
JOBS_LIST="${CLUSTER_PROFILE_DIR}/${WATCHER_BOT_JOB_FILE}"
SECRETS_DIR="/tmp/bot_secrets"
MENTIONED_GROUP_ID=$(cat "${SECRETS_DIR}/${WATCHER_BOT_MENTIONED_GROUP_ID_SECRET_NAME}")
WEBHOOK_URL=$(cat "${SECRETS_DIR}/${WATCHER_BOT_WEBHOOK_URL_SECRET_NAME}")

echo "Executing interop-ocp-watcher-bot..."
interop-ocp-watcher-bot --job_file_path="${JOBS_LIST}" --mentioned_group_id="${MENTIONED_GROUP_ID}" --webhook_url="${WEBHOOK_URL}" --job_group_name="${WATCHER_BOT_JOB_GROUP_NAME}"
