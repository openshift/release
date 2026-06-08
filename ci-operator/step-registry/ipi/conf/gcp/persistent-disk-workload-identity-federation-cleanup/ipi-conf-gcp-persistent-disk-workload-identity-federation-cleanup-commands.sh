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
	echo "Running Command: ${CMD}" >&2
	eval "${CMD}"
}

function backoff() {
	local attempt=0
	local failed=0
	echo "INFO: Running Command '$*'"
	while true; do
		eval "$*" && failed=0 || failed=1
		if [[ $failed -eq 0 ]]; then
			break
		fi
		attempt=$(( attempt + 1 ))
		if [[ $attempt -gt 5 ]]; then
			break
		fi
		echo "command failed, retrying in $(( 2 ** attempt )) seconds"
		sleep $(( 2 ** attempt ))
	done
	return $failed
}

logger "INFO" "Starting GCP Persistent Disk Workload Identity Federation cleanup"

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

logger "INFO" "Cleaning up GCP Persistent Disk Workload Identity Federation configuration"

# Find existing service account created for GCP PD CSI driver by the installer
CLUSTER_NAME=$(jq -r .clusterName ${SHARED_DIR}/metadata.json)
SA_FILTER="displayName:${CLUSTER_NAME}-openshift-gcp-pd-csi-*" # can be truncated
SERVICE_ACCOUNT_EMAIL=$(run_command "gcloud iam service-accounts list --filter=\"${SA_FILTER}\" --format=\"json\" | jq -r .[0].email")
if [ -n "${SERVICE_ACCOUNT_EMAIL}" ]; then
	logger "INFO" "Found GCP PD IAM service account: ${SERVICE_ACCOUNT_EMAIL}"
else
	logger "ERROR" "Failed to find GCP PD IAM service account"
	exit 1
fi

# Determine the node service accounts to use
# The node service accounts are InfraID plus -m (master) or -w (worker).
# Ref: https://github.com/openshift/installer/blob/main/pkg/infrastructure/gcp/clusterapi/iam.go#L30
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
CONFIG="${SHARED_DIR}/install-config.yaml"

# Determine master node service account
# Default to InfraID-based service account
MASTER_NODE_SA="${INFRA_ID}-m@${SA_SUFFIX}"

# Override with custom service account if specified in install-config.yaml
CUSTOM_CONTROL_PLANE_SA=""
if [ -f "${CONFIG}" ]; then
	CUSTOM_CONTROL_PLANE_SA=$(yq-go r "${CONFIG}" 'controlPlane.platform.gcp.serviceAccount' 2>/dev/null || echo "")
fi

if [ -n "${CUSTOM_CONTROL_PLANE_SA}" ] && [ "${CUSTOM_CONTROL_PLANE_SA}" != "null" ]; then
	MASTER_NODE_SA="${CUSTOM_CONTROL_PLANE_SA}"
	logger "INFO" "Using master node service account from install-config.yaml: ${MASTER_NODE_SA}"
fi

# Determine worker node service account
# Default to InfraID-based service account
WORKER_NODE_SA="${INFRA_ID}-w@${SA_SUFFIX}"

# Override with custom service account if specified in install-config.yaml
CUSTOM_COMPUTE_SA=""
if [ -f "${CONFIG}" ]; then
	CUSTOM_COMPUTE_SA=$(yq-go r "${CONFIG}" 'compute[0].platform.gcp.serviceAccount' 2>/dev/null || echo "")
fi

if [ -n "${CUSTOM_COMPUTE_SA}" ] && [ "${CUSTOM_COMPUTE_SA}" != "null" ]; then
	WORKER_NODE_SA="${CUSTOM_COMPUTE_SA}"
	logger "INFO" "Using worker node service account from install-config.yaml: ${WORKER_NODE_SA}"
fi

# Remove scoped serviceAccountUser role from node service accounts
SA_USER_ROLE="roles/iam.serviceAccountUser"
logger "INFO" "Removing ${SA_USER_ROLE} from node service accounts: ${MASTER_NODE_SA}, ${WORKER_NODE_SA}"
CMD="gcloud iam service-accounts remove-iam-policy-binding \"${MASTER_NODE_SA}\" --project=\"${GOOGLE_PROJECT_ID}\" --member=\"serviceAccount:${SERVICE_ACCOUNT_EMAIL}\" --role=\"${SA_USER_ROLE}\" --condition=None"
backoff "${CMD}"
CMD="gcloud iam service-accounts remove-iam-policy-binding \"${WORKER_NODE_SA}\" --project=\"${GOOGLE_PROJECT_ID}\" --member=\"serviceAccount:${SERVICE_ACCOUNT_EMAIL}\" --role=\"${SA_USER_ROLE}\" --condition=None"
backoff "${CMD}"

logger "INFO" "IAM roles removed successfully"

logger "INFO" "GCP Persistent Disk Workload Identity Federation cleanup completed"
