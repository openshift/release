#!/bin/bash

# Strict mode
set -o nounset
set -o errexit
set -o pipefail

# Global constants
readonly POWERVC_TOOL_VERSION="v2.2.0"
readonly YQ_VERSION="v4.49.2"
readonly MAX_DESTROY_ATTEMPTS=3
readonly SECRETS_DIR="/var/run/powervc-ipi-cicd-secrets/powervc-creds"

#######################################
# Log an informational message with timestamp
# Arguments:
#   Message to log
#######################################
function log_info() {
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*"
}

#######################################
# Log an error message with timestamp
# Arguments:
#   Message to log
#######################################
function log_error() {
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

#######################################
# Log a warning message with timestamp
# Arguments:
#   Message to log
#######################################
function log_warning() {
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2
}

#######################################
# Install required tools for PowerVC operations
# Downloads and configures PowerVC-Tool, yq, and OpenStack credentials
# Globals:
#   SECRETS_DIR, HOME, PATH
# Returns:
#   0 on success, 1 on failure
#######################################
function install_required_tools() {
	log_info "Installing required tools..."

	cd /tmp || {
		log_error "Failed to change to /tmp directory"
		return 1
	}

	HOME=/tmp
	export HOME

	mkdir -p /tmp/bin || {
		log_error "Failed to create /tmp/bin directory"
		return 1
	}

	PATH="/tmp/bin:${PATH}"
	export PATH

	# Install PowerVC-Tool
	log_info "Installing PowerVC-Tool version ${POWERVC_TOOL_VERSION}"
	local machine
	machine=$(uname -m)
	if [[ "${machine}" == "x86_64" ]]; then 
		machine="amd64"
	fi

	local tool_bin="ocp-ipi-powervc-linux-${machine}"
	local tool_url="https://github.com/IBM/ocp-ipi-powervc/releases/download/${POWERVC_TOOL_VERSION}/${tool_bin}"

	if ! curl --location --fail --silent --show-error --output /tmp/bin/PowerVC-Tool "${tool_url}"; then
		log_error "Failed to download PowerVC-Tool"
		exit 1
	fi
	chmod ugo+x /tmp/bin/PowerVC-Tool

	# Install yq-v4 if not present
	log_info "Checking for yq-v4..."
	local cmd_yq
	cmd_yq="$(command -v yq-v4 2>/dev/null || true)"

	if [[ ! -x "${cmd_yq}" ]]; then
		log_info "Installing yq-v4 version ${YQ_VERSION}"
		local yq_arch
		yq_arch=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
		local yq_url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${yq_arch}"

		if ! curl --fail --location --silent --show-error "${yq_url}" -o /tmp/bin/yq-v4; then
			log_error "Failed to download yq-v4 from ${yq_url}"
			return 1
		fi
		chmod +x /tmp/bin/yq-v4
	else
		log_info "yq-v4 already installed at ${cmd_yq}"
	fi

	# Setup OpenStack credentials
	log_info "Setting up OpenStack credentials..."
	mkdir -p "${HOME}/.config/openstack/" || {
		log_error "Failed to create OpenStack config directory"
		return 1
	}

	if [[ ! -f "${SECRETS_DIR}/clouds.yaml" ]]; then
		log_error "clouds.yaml not found at ${SECRETS_DIR}/clouds.yaml"
		return 1
	fi

	if [[ ! -f "${SECRETS_DIR}/ocp-ci-ca.pem" ]]; then
		log_error "ocp-ci-ca.pem not found at ${SECRETS_DIR}/ocp-ci-ca.pem"
		return 1
	fi

	cp "${SECRETS_DIR}/clouds.yaml" "${HOME}/.config/openstack/" || {
		log_error "Failed to copy clouds.yaml to .config/openstack/"
		return 1
	}

	cp "${SECRETS_DIR}/clouds.yaml" "${HOME}/" || {
		log_error "Failed to copy clouds.yaml to HOME"
		return 1
	}

	cp "${SECRETS_DIR}/ocp-ci-ca.pem" "${HOME}/" || {
		log_error "Failed to copy ocp-ci-ca.pem"
		return 1
	}

	# Verify tools are available
	log_info "Verifying installed tools..."
	local tools=("PowerVC-Tool" "jq" "yq-v4" "openstack")
	for tool in "${tools[@]}"; do
		if ! command -v "${tool}" &>/dev/null; then
			log_error "Required tool '${tool}' is not available"
			return 1
		fi
		log_info "✓ ${tool} is available at $(command -v "${tool}")"
	done

	log_info "All required tools installed successfully"
	return 0
}

#######################################
# Cleanup OpenStack containers and objects one at a time
# This is a workaround for bulk deletion failures
# Args:
#   $1: Cloud name
#   $2: Infrastructure ID to filter containers
# Returns: 0 on success, 1 on failure
#######################################
function hack_cleanup_containers() {
	local cloud="${1:-}"
	local infra_id="${2:-}"

	if [[ -z "${cloud}" ]] || [[ -z "${infra_id}" ]]; then
		log_error "hack_cleanup_containers requires cloud and infra_id parameters"
		return 1
	fi

	log_info "Cleaning up OpenStack containers for infrastructure: ${infra_id}"

	# List all containers
	if ! openstack --os-cloud="${cloud}" container list --format csv &>/dev/null; then
		log_warning "Failed to list containers or no containers found"
		return 0
	fi

	local container_count=0
	local object_count=0

	# Process each container matching the infrastructure ID
	while IFS= read -r container; do
		[[ -z "${container}" ]] && continue

		container_count=$((container_count + 1))
		log_info "Processing container: ${container}"

		# Delete all objects in the container
		while IFS= read -r object; do
			[[ -z "${object}" ]] && continue

			object_count=$((object_count + 1))
			log_info "Deleting object: ${object} from container: ${container}"

			if ! openstack --os-cloud="${cloud}" object delete "${container}" "${object}"; then
				log_warning "Failed to delete object: ${object}"
			fi
		done < <(openstack --os-cloud="${cloud}" object list "${container}" --format csv 2>/dev/null | sed -e '/\(Name\)/d' -e 's,",,g')

		# Delete the container itself
		log_info "Deleting container: ${container}"
		if ! openstack --os-cloud="${cloud}" container delete "${container}"; then
			log_warning "Failed to delete container: ${container}"
		fi
	done < <(openstack --os-cloud="${cloud}" container list --format csv 2>/dev/null | sed -e '/\(Name\|container_name\)/d' -e 's,",,g' | grep -F -- "${infra_id}" || true)

	log_info "Container cleanup complete. Processed ${container_count} containers and ${object_count} objects"
	return 0
}

#######################################
# Validate required environment variables and files
# Returns: 0 if valid, 1 if validation fails
#######################################
function validate_environment() {
	log_info "Validating environment..."

	local validation_failed=0
	local has_metadata=1

	# Check for metadata.json
	if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
		log_error "metadata.json not found or empty at ${SHARED_DIR}/metadata.json"
		has_metadata=0
	else
		log_info "${SHARED_DIR}/metadata.json found"
	fi

	# Check for powervc-conf.yaml
	if [[ ! -f "${SHARED_DIR}/powervc-conf.yaml" ]]; then
		log_error "powervc-conf.yaml not found at ${SHARED_DIR}/powervc-conf.yaml"
		validation_failed=1
	fi

	# Check for credentials
	if [[ ! -f "${SECRETS_DIR}/IBMCLOUD_API_KEY" ]]; then
		log_error "IBMCLOUD_API_KEY not found at ${SECRETS_DIR}/IBMCLOUD_API_KEY"
		validation_failed=1
	fi

	if [[ ${validation_failed} -eq 1 ]]; then
		log_error "Environment validation failed"
		return 1
	fi

	log_info "Environment validation successful"

	export HAS_METADATA=${has_metadata}

	return 0
}

#######################################
# Copy artifacts to the artifact directory
# Args:
#   $1: Source directory
# Returns: 0 on success
#######################################
function copy_artifacts() {
	local source_dir="${1:-/tmp/installer}"

	log_info "Copying artifacts from ${source_dir} to ${ARTIFACT_DIR}..."

	if [[ -f "${source_dir}/.openshift_install.log" ]]; then
		cp "${source_dir}/.openshift_install.log" "${ARTIFACT_DIR}/" || {
			log_warning "Failed to copy .openshift_install.log"
		}
	else
		log_warning "No .openshift_install.log found at ${source_dir}"
	fi

	if [[ -s "${source_dir}/quota.json" ]]; then
		cp "${source_dir}/quota.json" "${ARTIFACT_DIR}/" || {
			log_warning "Failed to copy quota.json"
		}
	fi

	log_info "Artifact copy complete"
	return 0
}

#######################################
# Cleanup handler for trap
#######################################
function cleanup_on_exit() {
	local exit_code=$?
	log_info "Cleanup handler triggered with exit code: ${exit_code}"

	# Kill any child processes
	local children
	children=$(jobs -p 2>/dev/null || true)
	if [[ -n "${children}" ]]; then
		log_info "Killing child processes: ${children}"
		# shellcheck disable=SC2086
		kill ${children} 2>/dev/null || true
		wait 2>/dev/null || true
	fi

	return "${exit_code}"
}

#######################################
# Calls the IPI to destroy the cluster
# Returns: 0 on success
#######################################
function destroy_cluster() {
	log_info "Running cluster destroy command (max ${MAX_DESTROY_ATTEMPTS} attempts)..."

	OPENSHIFT_INSTALL_REPORT_QUOTA_FOOTPRINT="true"
	export OPENSHIFT_INSTALL_REPORT_QUOTA_FOOTPRINT

	local destroy_result=1
	local attempt

	for attempt in $(seq 1 "${MAX_DESTROY_ATTEMPTS}"); do
		log_info "Destroy attempt ${attempt}/${MAX_DESTROY_ATTEMPTS}"
		log_info "Timestamp: $(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"

		if openshift-install --dir "${installer_dir}" destroy cluster; then
			destroy_result=0
			log_info "Cluster destroy successful on attempt ${attempt}"
			break
		else
			destroy_result=$?
			log_warning "Cluster destroy failed on attempt ${attempt} with exit code ${destroy_result}"

			if [[ ${attempt} -lt ${MAX_DESTROY_ATTEMPTS} ]]; then
				log_info "Waiting 30 seconds before retry..."
				sleep 30
			fi
		fi
	done

	# Delete metadata if destroy was successful
	if [[ ${destroy_result} -eq 0 ]]; then
		log_info "Deleting metadata from PowerVC server..."
		if PowerVC-Tool send-metadata \
			--deleteMetadata "${installer_dir}/metadata.json" \
			--serverIP "${SERVER_IP}" \
			--shouldDebug true; then
			log_info "Metadata deleted successfully"
		else
			log_warning "Failed to delete metadata, but cluster destroy was successful"
		fi
	else
		log_error "Cluster destroy failed after ${MAX_DESTROY_ATTEMPTS} attempts"
		return 1
	fi

	return 0
}

#######################################
# Deletes the OpenStack keypair
# Returns: 0 on success
#######################################
function delete_keypair() {
	# Delete the keypair
	log_info "Deleting SSH keypair..."

	if ! openstack --os-cloud="${CLOUD}" keypair delete "${CLUSTER_NAME}-key" 2>/dev/null; then
		log_warning "Failed to delete SSH keypair"
	fi

	return 0
}

#######################################
# Main execution
#######################################
function main() {
	log_info "Starting PowerVC cluster deprovision process..."
	local destroy_result=0

	# Set up trap for cleanup
	trap cleanup_on_exit EXIT
	trap 'cleanup_on_exit; exit 143' TERM
	trap 'cleanup_on_exit; exit 130' INT

	# Validate environment first
	if ! validate_environment; then
		log_error "Environment validation failed, skipping deprovision"
		return 1
	fi

	# Set up IBMCLOUD API key
	IBMCLOUD_API_KEY=$(cat "${SECRETS_DIR}/IBMCLOUD_API_KEY")
	export IBMCLOUD_API_KEY

	# Install required tools
	if ! install_required_tools; then
		log_error "Failed to install required tools"
		return 1
	fi

	# Extract configuration from powervc-conf.yaml
	log_info "Reading configuration from ${SHARED_DIR}/powervc-conf.yaml"
	CLOUD=$(yq-v4 eval '.CLOUD' "${SHARED_DIR}/powervc-conf.yaml")
	CLUSTER_NAME=$(yq-v4 eval '.CLUSTER_NAME' "${SHARED_DIR}/powervc-conf.yaml")
	LEASED_RESOURCE=$(yq-v4 eval '.LEASED_RESOURCE' "${SHARED_DIR}/powervc-conf.yaml")
	SERVER_IP=$(yq-v4 eval '.SERVER_IP' "${SHARED_DIR}/powervc-conf.yaml")

	# Validate extracted values
	if [[ -z "${CLOUD}" ]] || [[ "${CLOUD}" == "null" ]]; then
		log_error "CLOUD value is empty or null"
		return 1
	fi

	# Extract infrastructure ID from metadata.json (only if present)
	INFRAID=""
	if [[ ${HAS_METADATA} -eq 1 ]]; then
		INFRAID=$(jq -r .infraID "${SHARED_DIR}/metadata.json")
		if [[ -z "${INFRAID}" ]] || [[ "${INFRAID}" == "null" ]]; then
			log_error "INFRAID value is empty or null"
			return 1
		fi
	fi

	log_info "Configuration loaded:"
	log_info "  CLOUD: ${CLOUD}"
	log_info "  CLUSTER_NAME: ${CLUSTER_NAME}"
	log_info "  INFRAID: ${INFRAID}"
	log_info "  LEASED_RESOURCE: ${LEASED_RESOURCE}"
	log_info "  SERVER_IP: ${SERVER_IP}"

	export CLOUD
	export INFRAID
	export LEASED_RESOURCE

	# Cleanup containers before destroying cluster
	if [[ ${HAS_METADATA} -eq 1 ]] && [[ -n "${INFRAID}" ]]; then
		if ! hack_cleanup_containers "${CLOUD}" "${INFRAID}"; then
			log_warning "Container cleanup encountered issues, continuing with cluster destroy"
		fi
	else
		log_info "Skipping container cleanup (no metadata/infraID available)"
	fi

	# Prepare installer directory
	log_info "Preparing installer directory..."
	local installer_dir="/tmp/installer"
	mkdir -p "${installer_dir}" || {
		log_error "Failed to create installer directory"
		return 1
	}

	cp -a "${SHARED_DIR}/." "${installer_dir}/" || {
		log_error "Failed to copy shared directory contents"
		return 1
	}

	# Run cluster destroy with retries
	if [[ ${HAS_METADATA} -eq 1 ]]; then
		if destroy_cluster; then
			destroy_result=0
		else
			destroy_result=$?
			log_warning "Could not destroy the OpenShift cluster"
		fi
	fi

	# Delete the OpenStack keypair
	delete_keypair

	# NOTE: The bastion is a persistent resource!

	# Copy artifacts regardless of success/failure
	copy_artifacts "${installer_dir}"

	log_info "Deprovision process complete with exit code: ${destroy_result}"
	return "${destroy_result}"
}

# Execute main function
main
exit $?

# Made with Bob
