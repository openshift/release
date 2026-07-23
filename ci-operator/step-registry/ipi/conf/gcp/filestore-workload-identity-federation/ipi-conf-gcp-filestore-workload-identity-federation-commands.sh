#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

INFRA_NAME=${NAMESPACE}-${UNIQUE_HASH}

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
    echo "Running Command: ${CMD}" >&2
    eval "${CMD}"
}

logger "INFO" "Starting GCP Filestore Workload Identity Federation configuration"

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1091
	source "${SHARED_DIR}/proxy-conf.sh"
	logger "INFO" "Loaded proxy configuration from ${SHARED_DIR}/proxy-conf.sh"
fi

GOOGLE_PROJECT_ID="$(<${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
GCP_SERVICE_ACCOUNT=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
SA_SUFFIX=${GCP_SERVICE_ACCOUNT#*@}
SA_EMAIL=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})

if ! gcloud auth list | grep -E "\*\s+${SA_EMAIL}"
then
  logger "INFO" "Authenticating with GCP service account"
  CMD="gcloud auth activate-service-account --key-file=\"${GCP_SHARED_CREDENTIALS_FILE}\""
  run_command "${CMD}"
  CMD="gcloud config set project \"${GOOGLE_PROJECT_ID}\""
  run_command "${CMD}"
  logger "INFO" "Successfully authenticated with GCP service account"
fi

# Ref: TBD (no Red Hat docs available yet). Google doc: https://cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes#create_the_workload_identity_pool_and_provider
logger "INFO" "Create GCP Filestore cloud infrastructure for Workload Identity Federation"

## TODO: replace steps to manually create the service account and bindings with ccoctl automation if this ever gets implemented
## TODO: alternatively, this could be documented later in the docs, make sure the code below is aligned with the official procedure

# Create Google cloud service account for GCP Filestore Operator (name length must be between 6 and 30)
SERVICE_ACCOUNT_NAME="gcp-filestore-sa-${UNIQUE_HASH}"-`echo $RANDOM`
SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_NAME}@${SA_SUFFIX}"

logger "INFO" "Creating GCP IAM service account: ${SERVICE_ACCOUNT_EMAIL}"
CMD="gcloud iam service-accounts create \"$SERVICE_ACCOUNT_NAME\" --display-name=\"$SERVICE_ACCOUNT_NAME\""
run_command "$CMD"

# Obtain project number, pool ID, and provider ID
# We assume the pool ID is the same as the infrastructure name and reuse it. If this won't work well in the future we can create a new pool for the operator.
logger "INFO" "Obtaining project details and identity pool information"
CMD="gcloud projects describe \"$GOOGLE_PROJECT_ID\" --format=\"value(projectNumber)\""
PROJECT_NUMBER=$(run_command "${CMD}")
POOL_ID=${INFRA_NAME}
PROVIDER_ID=${INFRA_NAME}
logger "INFO" "Project number: ${PROJECT_NUMBER}, Pool ID: ${POOL_ID}, Provider ID: ${PROVIDER_ID}"

# Set roles for the service account - this should match roles CredentialsRequest of Filestore Operator
logger "INFO" "Setting IAM roles for the service account"
CMD="gcloud projects add-iam-policy-binding \"$GOOGLE_PROJECT_ID\" --member=\"serviceAccount:$SERVICE_ACCOUNT_EMAIL\" --role=\"roles/file.editor\" --condition=None"
run_command "${CMD}"
CMD="gcloud projects add-iam-policy-binding \"$GOOGLE_PROJECT_ID\" --member=\"serviceAccount:$SERVICE_ACCOUNT_EMAIL\" --role=\"roles/resourcemanager.tagUser\" --condition=None"
run_command "${CMD}"
logger "INFO" "IAM roles set successfully"

# Allow OpenShift service accounts to impersonate Google cloud service account
logger "INFO" "Configuring Workload Identity Federation for OpenShift service accounts"
CMD="gcloud iam service-accounts add-iam-policy-binding \"$SERVICE_ACCOUNT_EMAIL\" --member=\"principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL_ID/subject/system:serviceaccount:openshift-cluster-csi-drivers:gcp-filestore-csi-driver-controller-sa\" --role=roles/iam.workloadIdentityUser"
run_command "${CMD}"
CMD="gcloud iam service-accounts add-iam-policy-binding \"$SERVICE_ACCOUNT_EMAIL\" --member=\"principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL_ID/subject/system:serviceaccount:openshift-cluster-csi-drivers:gcp-filestore-csi-driver-operator\" --role=roles/iam.workloadIdentityUser"
run_command "${CMD}"
logger "INFO" "Workload Identity Federation configured successfully"

# Store GCP WIF variables to a known location to be used later in chain as OO_CONFIG_ENVVARS used by `optional-operators-subscribe` step
logger "INFO" "Storing GCP Workload Identity Federation variables"
echo "$POOL_ID"  > "${SHARED_DIR}"/gcp-filestore-pool-id
echo "$PROVIDER_ID"  > "${SHARED_DIR}"/gcp-filestore-provider-id
echo "$SERVICE_ACCOUNT_EMAIL"  > "${SHARED_DIR}"/gcp-filestore-service-account-email
printf '"%s"' "$PROJECT_NUMBER" > "${SHARED_DIR}"/gcp-filestore-project-number

logger "INFO" "GCP Workload Identity Federation variables stored successfully in ${SHARED_DIR}:"
logger "INFO" "  Pool ID: $(cat ${SHARED_DIR}/gcp-filestore-pool-id)"
logger "INFO" "  Provider ID: $(cat ${SHARED_DIR}/gcp-filestore-provider-id)"
logger "INFO" "  Service Account Email: $(cat ${SHARED_DIR}/gcp-filestore-service-account-email)"
logger "INFO" "  Project Number: $(cat ${SHARED_DIR}/gcp-filestore-project-number)"

logger "INFO" "GCP Filestore Workload Identity Federation configuration completed"

