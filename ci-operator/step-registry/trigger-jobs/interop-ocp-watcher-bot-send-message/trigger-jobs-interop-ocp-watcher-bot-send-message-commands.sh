#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# Get the day of the month
month_day=$(date +%-d)

# additional checks for self-managed fips and non-fips testing
self_managed_string='self-managed-lp-interop-jobs'
zstream_string='zstream'
fips_string='fips'

# only report self-managed fips if date <= 7 and non-fips scenarios if date > 7 .
echo "Checking to see if it is a test day for ${WATCHER_BOT_JOB_FILE}"
if [[ $WATCHER_BOT_JOB_FILE == *"${self_managed_string}"* &&
        $WATCHER_BOT_JOB_FILE != *"$fips_string"* &&
        $WATCHER_BOT_JOB_FILE != *"$zstream_string"* ]]; then
  if (( $month_day > 7 )); then
    echo "Reporting jobs because it's a Monday not in the first week of the month."
    echo "Continue..."
  else
    echo "We do not run self-managed scenarios on first week of the month, skip reporting"
    exit 0
  fi
fi

if [[ $WATCHER_BOT_JOB_FILE == *"${self_managed_string}"* &&
        $WATCHER_BOT_JOB_FILE == *"$fips_string"* &&
        $WATCHER_BOT_JOB_FILE != *"$zstream_string"* ]]; then
  if (( $month_day <= 7 )); then
    echo "Reporting jobs because it's the first Monday of the month."
    echo "Continue..."
  else
    echo "We do not run self-managed fips scenarios past the first Monday of the month, skip reporting"
    exit 0
  fi
fi

CLUSTER_PROFILE_DIR="/run/secrets/ci.openshift.io/cluster-profile"
JOBS_LIST="${CLUSTER_PROFILE_DIR}/${WATCHER_BOT_JOB_FILE}"
SECRETS_DIR="/tmp/bot_secrets"
MENTIONED_GROUP_ID=$(cat "${SECRETS_DIR}/${WATCHER_BOT_MENTIONED_GROUP_ID_SECRET_NAME}")
WEBHOOK_URL=$(cat "${SECRETS_DIR}/${WATCHER_BOT_WEBHOOK_URL_SECRET_NAME}")

echo "Executing interop-ocp-watcher-bot..."
interop-ocp-watcher-bot --job_file_path="${JOBS_LIST}" --mentioned_group_id="${MENTIONED_GROUP_ID}" --webhook_url="${WEBHOOK_URL}" --job_group_name="${WATCHER_BOT_JOB_GROUP_NAME}"
