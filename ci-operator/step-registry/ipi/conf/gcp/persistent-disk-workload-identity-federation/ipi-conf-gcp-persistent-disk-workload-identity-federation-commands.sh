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

logger "INFO" "Starting GCP Persistent Disk Workload Identity Federation configuration"

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

# Refs:
#   https://github.com/kubernetes-sigs/gcp-compute-persistent-disk-csi-driver/blob/master/docs/kubernetes/user-guides/driver-install.md
#   https://github.com/kubernetes-sigs/gcp-compute-persistent-disk-csi-driver/blob/master/deploy/setup-project.sh
logger "INFO" "Configure GCP Persistent Disk for Workload Identity Federation"

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

# The node service accounts are InfraID plus -m (master) or -w (worker).
# Ref: https://github.com/openshift/installer/blob/main/pkg/infrastructure/gcp/clusterapi/iam.go#L30
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
MASTER_NODE_SA="${INFRA_ID}-m@${SA_SUFFIX}"
WORKER_NODE_SA="${INFRA_ID}-w@${SA_SUFFIX}"

# Grant scoped serviceAccountUser role for node service accounts
SA_USER_ROLE="roles/iam.serviceAccountUser"
logger "INFO" "Granting ${SA_USER_ROLE} for node service accounts: ${MASTER_NODE_SA}, ${WORKER_NODE_SA}"
CMD="gcloud iam service-accounts add-iam-policy-binding \"${MASTER_NODE_SA}\" --project=\"${GOOGLE_PROJECT_ID}\" --member=\"serviceAccount:${SERVICE_ACCOUNT_EMAIL}\" --role=\"${SA_USER_ROLE}\" --condition=None"
run_command "${CMD}"
CMD="gcloud iam service-accounts add-iam-policy-binding \"${WORKER_NODE_SA}\" --project=\"${GOOGLE_PROJECT_ID}\" --member=\"serviceAccount:${SERVICE_ACCOUNT_EMAIL}\" --role=\"${SA_USER_ROLE}\" --condition=None"
run_command "${CMD}"

# Remove project-level serviceAccountUser role from the binding created by the installer
logger "INFO" "Removing ${SA_USER_ROLE} from project-level binding for ${SERVICE_ACCOUNT_EMAIL}"
CMD="gcloud projects remove-iam-policy-binding \"${GOOGLE_PROJECT_ID}\" --member=\"serviceAccount:${SERVICE_ACCOUNT_EMAIL}\" --role=\"${SA_USER_ROLE}\" --condition=None"
backoff "${CMD}"

logger "INFO" "IAM roles set successfully"

logger "INFO" "GCP Persistent Disk Workload Identity Federation configuration completed"
