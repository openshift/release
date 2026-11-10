#!/bin/bash

# Exit on errors, unset variables, and failed pipelines.
set -o nounset
set -o errexit
set -o pipefail

# Tunable retry constants (can be overridden via env vars).
readonly MAX_CLEANUP_ATTEMPTS="${MAX_CLEANUP_ATTEMPTS:-10}"
readonly CLEANUP_RETRY_DELAY="${CLEANUP_RETRY_DELAY:-15}"

# Secrets directory mounted by the CI infrastructure.
export SECRETS_DIR="/var/run/powervc-ipi-cicd-secrets/powervc-creds"
readonly SECRETS_DIR

#######################################
# Log an informational message with a timestamp.
# Arguments:
#   Message text.
#######################################
function log_info() {
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*"
}

#######################################
# Log an error message with a timestamp.
# Arguments:
#   Message text.
#######################################
function log_error() {
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

#######################################
# Log a warning message with a timestamp.
# Arguments:
#   Message text.
#######################################
function log_warning() {
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $*" >&2
}

#######################################
# Confirm that all environment variables required by the step are
# non-empty before any work begins.
#
# Globals:
#   CLOUD – (in) must be non-empty; validated but not modified.
# Returns:
#   0 if all required variables are set; 1 if any are absent.
#######################################
function validate_environment() {
	log_info "Validating environment variables..."

	local required_vars=(
		"CLOUD"
	)

	local missing_vars=()
	for var in "${required_vars[@]}"; do
		if [[ -z "${!var:-}" ]]; then
			missing_vars+=("${var}")
		fi
	done

	if [[ ${#missing_vars[@]} -gt 0 ]]; then
		log_error "Missing required environment variables: ${missing_vars[*]}"
		return 1
	fi

	log_info "All required environment variables are set"
	return 0
}

#######################################
# Set up a private HOME directory and install OpenStack credentials.
#
# Globals:
#   SECRETS_DIR – (in) directory containing clouds.yaml and ocp-ci-ca.pem.
#   HOME        – (out) set to a newly created private temporary directory.
# Returns:
#   0 on success; 1 on failure.
#######################################
function setup_credentials() {
	log_info "Setting up OpenStack credentials..."

	cd /tmp || {
		log_error "Failed to change directory to /tmp"
		return 1
	}

	# Make a private directory that is only readable by us.
	HOME="$(mktemp -d /var/tmp/powervc-cleanup.XXXXXX)"
	chmod 0700 "${HOME}"
	log_info "HOME is now ${HOME}"
	export HOME

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

	install -m 0600 "${SECRETS_DIR}/clouds.yaml" "${HOME}/.config/openstack/clouds.yaml" || {
		log_error "Failed to copy clouds.yaml to .config/openstack/"
		return 1
	}

	install -m 0600 "${SECRETS_DIR}/clouds.yaml" "${HOME}/clouds.yaml" || {
		log_error "Failed to copy clouds.yaml to HOME"
		return 1
	}

	install -m 0600 "${SECRETS_DIR}/ocp-ci-ca.pem" "${HOME}/ocp-ci-ca.pem" || {
		log_error "Failed to copy ocp-ci-ca.pem"
		return 1
	}

	# Rewrite CA path in clouds.yaml to point to HOME location.
	sed -i -e "s|/tmp/ocp-ci-ca.pem|${HOME}/ocp-ci-ca.pem|" "${HOME}/clouds.yaml"
	sed -i -e "s|/tmp/ocp-ci-ca.pem|${HOME}/ocp-ci-ca.pem|" "${HOME}/.config/openstack/clouds.yaml"

	# Verify openstack and jq are available.
	local tools=("openstack" "jq")
	for tool in "${tools[@]}"; do
		if ! command -v "${tool}" &>/dev/null; then
			log_error "Required tool '${tool}' is not available"
			return 1
		fi
		log_info "✓ ${tool} is available at $(command -v "${tool}")"
	done

	log_info "OpenStack credentials configured successfully"
	return 0
}

#######################################
# Find and delete virtual machines in ERROR state on the target cloud,
# looping until no virtual machines in ERROR state remain or until
# maximum attempts are exhausted.
#
# Globals:
#   CLOUD                – (in) name of the target cloud.
#   MAX_CLEANUP_ATTEMPTS – (in) maximum number of cleanup iterations.
#   CLEANUP_RETRY_DELAY  – (in) delay in seconds between iterations.
# Returns:
#   0 if all ERROR VMs were cleaned up; 1 if ERROR VMs remain or errors occurred.
#######################################
function cleanup_error_vms() {
	log_info "Starting cleanup loop for virtual machines in ERROR state on cloud '${CLOUD}'..."

	local attempt=1
	while [[ ${attempt} -le ${MAX_CLEANUP_ATTEMPTS} ]]; do
		log_info "Checking for virtual machines in ERROR state (attempt ${attempt}/${MAX_CLEANUP_ATTEMPTS})..."

		local error_vms
		if ! error_vms="$(openstack --os-cloud="${CLOUD}" server list --status ERROR -f json 2>/dev/null)"; then
			log_warning "Failed to query server list from cloud '${CLOUD}' on attempt ${attempt}"
			if [[ ${attempt} -lt ${MAX_CLEANUP_ATTEMPTS} ]]; then
				log_info "Retrying query in ${CLEANUP_RETRY_DELAY}s..."
				sleep "${CLEANUP_RETRY_DELAY}"
				attempt=$((attempt + 1))
				continue
			fi
			return 1
		fi

		local count
		count="$(echo "${error_vms}" | jq '. | length')"

		if [[ "${count}" -eq 0 ]]; then
			log_info "No virtual machines found in ERROR state. Cleanup complete."
			return 0
		fi

		log_info "Found ${count} virtual machine(s) in ERROR state. Initiating deletion..."

		local server_entries=()
		mapfile -t server_entries < <(echo "${error_vms}" | jq -r '.[] | "\(.ID)\t\(.Name)"')

		for entry in "${server_entries[@]}"; do
			[[ -z "${entry}" ]] && continue
			local server_id="${entry%%	*}"
			local server_name="${entry#*	}"

			log_info "Deleting VM in ERROR state: ${server_name} (${server_id})..."
			if ! openstack --os-cloud="${CLOUD}" server delete "${server_id}"; then
				log_warning "Failed to issue delete command for VM ${server_id} (${server_name})"
			fi
		done

		if [[ ${attempt} -lt ${MAX_CLEANUP_ATTEMPTS} ]]; then
			log_info "Waiting ${CLEANUP_RETRY_DELAY}s for deletions to process before verifying..."
			sleep "${CLEANUP_RETRY_DELAY}"
		fi

		attempt=$((attempt + 1))
	done

	# Final check after all attempts have been exhausted
	log_info "Checking if any virtual machines in ERROR state remain after ${MAX_CLEANUP_ATTEMPTS} attempts..."
	local remaining_vms
	if remaining_vms="$(openstack --os-cloud="${CLOUD}" server list --status ERROR -f json 2>/dev/null)"; then
		local remaining_count
		remaining_count="$(echo "${remaining_vms}" | jq '. | length')"
		if [[ "${remaining_count}" -eq 0 ]]; then
			log_info "All virtual machines in ERROR state successfully cleaned up."
			return 0
		fi
		log_error "Virtual machines in ERROR state still remain after ${MAX_CLEANUP_ATTEMPTS} attempts (${remaining_count} remaining)."
		return 1
	fi

	log_error "Failed to verify final cleanup status."
	return 1
}

#######################################
# Entry point for the PowerVC cleanup VM error step.
# Errors are logged, but the step always exits 0 (best-effort) so downstream
# workflow steps are not blocked.
#######################################
function main() {
	log_info "=== PowerVC Cleanup VM Error Script Started ==="

	if [[ ! -d "${SECRETS_DIR}" ]]; then
		log_error "Secrets directory does not exist: ${SECRETS_DIR}"
		log_warning "Skipping cleanup (non-fatal); continuing workflow"
		log_info "=== PowerVC Cleanup VM Error Script Completed ==="
		return 0
	fi

	if ! validate_environment; then
		log_error "Environment validation failed"
		log_warning "Skipping cleanup (non-fatal); continuing workflow"
		log_info "=== PowerVC Cleanup VM Error Script Completed ==="
		return 0
	fi

	if ! setup_credentials; then
		log_error "Failed to setup credentials"
		log_warning "Skipping cleanup (non-fatal); continuing workflow"
		log_info "=== PowerVC Cleanup VM Error Script Completed ==="
		return 0
	fi

	if ! cleanup_error_vms; then
		log_warning "Cleanup of VMs in ERROR state did not complete cleanly; continuing workflow"
	fi

	log_info "=== PowerVC Cleanup VM Error Script Completed ==="
	return 0
}

main || true
exit 0
