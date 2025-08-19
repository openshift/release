#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# logger function prints standard logs
logger() {
    local level="$1"
    local message="$2"
    local timestamp

    # Generate a timestamp for the log entry
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Print the log message with the level and timestamp
    echo "[$timestamp] [$level] $message"
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

logger "INFO" "Starting GCP Filestore Workload Identity Federation cleanup"

if [ -f "${SHARED_DIR}/gcp-filestore-service-account-email" ]; then
  SERVICE_ACCOUNT_EMAIL=$(cat "${SHARED_DIR}"/gcp-filestore-service-account-email)
else
  logger "INFO" "Service account email file not found in ${SHARED_DIR} - nothing to clean up."
  exit 0
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).

# The proxy is used to access cluster api, while there is no access to cluster, remove thispart
#if test -f "${SHARED_DIR}/proxy-conf.sh"
#then
#	# shellcheck disable=SC1091
#	source "${SHARED_DIR}/proxy-conf.sh"
#	logger "INFO" "Loaded proxy configuration from ${SHARED_DIR}/proxy-conf.sh"
#fi

GOOGLE_PROJECT_ID="$(<${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  logger "INFO" "Activating service account: ${sa_email}"
  cmd="gcloud auth activate-service-account --key-file=\"${GCP_SHARED_CREDENTIALS_FILE}\""
  run_command "$cmd"
  cmd="gcloud config set project \"${GOOGLE_PROJECT_ID}\""
  run_command "$cmd"
  logger "INFO" "Service account activated and project set to ${GOOGLE_PROJECT_ID}"
fi

# Ref: TBD (no Red Hat docs available yet). Google doc: https://cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes#create_the_workload_identity_pool_and_provider
logger "INFO" "Starting cleanup of GCP Filestore cloud infrastructure for Workload Identity Federation"

## TODO: replace cleanup steps with ccoctl automation if this ever gets implemented
## TODO: alternatively, this could be documented later in the docs, make sure the code below is aligned with the official procedure

# Delete the Google cloud service account
logger "INFO" "Deleting Google cloud service account: ${SERVICE_ACCOUNT_EMAIL}"
cmd="gcloud --quiet iam service-accounts delete \"$SERVICE_ACCOUNT_EMAIL\""
run_command "$cmd"
logger "INFO" "Service account removed"

logger "INFO" "GCP Filestore Workload Identity Federation cleanup completed"
