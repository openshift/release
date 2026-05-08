#!/bin/bash
# shellcheck disable=SC2128,SC2178

set -o nounset
set -o errexit
set -o pipefail
set -o errtrace

# Script: PowerVC IPI Installation
# Description: Installs OpenShift on PowerVC infrastructure
# Exit codes: 0=success, 1=general error, 2=validation error, 3=installation error
#
# Environment Variables Required:
#   OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE - Release image to install
#   SHARED_DIR - Directory for shared artifacts
#   ARTIFACT_DIR - Directory for test artifacts
#   CLUSTER_PROFILE_DIR - Directory containing cluster profile
#   JOB_NAME - CI job name
#   BUILD_ID - CI build ID
#
# Environment Variables Optional:
#   DEBUG - Enable debug logging (default: false)

# Global constants
readonly POWERVC_TOOL_VERSION="v2.2.0"
readonly YQ_VERSION="v4.49.2"
readonly IBMCLOUD_VERSION="2.43.0"

# Color codes for output (only use if terminal supports it)
if [[ -t 2 ]]; then
	readonly RED='\033[0;31m'
	readonly GREEN='\033[0;32m'
	readonly YELLOW='\033[1;33m'
	readonly NC='\033[0m'
else
	readonly RED=''
	readonly GREEN=''
	readonly YELLOW=''
	readonly NC=''
fi

# ============================================================================
# Logging Functions
# ============================================================================

# log_info - Log informational messages to stderr
# Arguments:
#   $* - Message to log
# Output:
#   Formatted log message with timestamp to stderr
function log_info() {
	local timestamp
	timestamp="$(date +'%Y-%m-%d %H:%M:%S')"
	echo -e "${GREEN}[${timestamp}] INFO:${NC} $*" >&2
}

# log_warn - Log warning messages to stderr
# Arguments:
#   $* - Warning message to log
# Output:
#   Formatted warning message with timestamp to stderr
function log_warn() {
	local timestamp
	timestamp="$(date +'%Y-%m-%d %H:%M:%S')"
	echo -e "${YELLOW}[${timestamp}] WARN:${NC} $*" >&2
}

# log_error - Log error messages to stderr
# Arguments:
#   $* - Error message to log
# Output:
#   Formatted error message with timestamp to stderr
function log_error() {
	local timestamp
	timestamp="$(date +'%Y-%m-%d %H:%M:%S')"
	echo -e "${RED}[${timestamp}] ERROR:${NC} $*" >&2
}

# log_debug - Log debug messages to stderr (only if DEBUG=true)
# Arguments:
#   $* - Debug message to log
# Output:
#   Formatted debug message with timestamp to stderr (if DEBUG enabled)
# Environment:
#   DEBUG - Set to "true" to enable debug logging
function log_debug() {
	if [[ "${DEBUG:-false}" == "true" ]]; then
		local timestamp
		timestamp="$(date +'%Y-%m-%d %H:%M:%S')"
		echo -e "[${timestamp}] DEBUG: $*" >&2
	fi
}

# ============================================================================
# Error Handling Functions
# ============================================================================

# Flag to prevent duplicate cleanup
CLEANUP_DONE=false

# error_handler - Handle script errors and prepare for cleanup
# Arguments:
#   $1 - Line number where error occurred
#   $2 - Exit code of failed command
# Output:
#   Error message to stderr
# Side Effects:
#   Calls prepare_next_steps for cleanup
function error_handler() {
	local line_no=$1
	local exit_code=$2
	log_error "Script failed at line ${line_no} with exit code ${exit_code}"
	# Don't call prepare_next_steps here - let EXIT trap handle it
	# The EXIT trap will fire automatically after this
}

trap 'error_handler ${LINENO} $?' ERR

# ============================================================================
# Utility Functions
# ============================================================================

# retry_command - Retry a command with exponential backoff
# Arguments:
#   $1 - Maximum number of attempts
#   $2 - Delay in seconds between attempts
#   $3 - Description of the operation
#   $@ - Command and arguments to execute
# Returns:
#   0 - Command succeeded
#   1 - Command failed after all attempts
# Example:
#   retry_command 3 5 "Download file" curl -O https://example.com/file
function retry_command() {
	local max_attempts="${1}"
	local delay="${2}"
	local description="${3}"
	shift 3
	local cmd=("$@")

	local attempt=1
	while (( attempt <= max_attempts )); do
		log_info "Attempt ${attempt}/${max_attempts}: ${description}"
		if "${cmd[@]}"; then
			log_info "Success: ${description}"
			return 0
		fi

		if (( attempt < max_attempts )); then
			log_warn "Failed, retrying in ${delay}s..."
			sleep "${delay}"
		fi
		((attempt++))
	done

	log_error "Failed after ${max_attempts} attempts: ${description}"
	return 1
}

# download_tool - Download and make executable a tool from URL
# Arguments:
#   $1 - URL to download from
#   $2 - Output file path
#   $3 - Description of the tool
# Returns:
#   0 - Download successful
#   1 - Download failed
# Side Effects:
#   Creates executable file at output path
function download_tool() {
	local url="${1}"
	local output="${2}"
	local description="${3}"

	log_info "Downloading ${description} from ${url}"
	retry_command 3 5 "Download ${description}" \
		curl --fail --location --silent --show-error --output "${output}" "${url}"
	chmod +x "${output}"
	log_info "Successfully installed ${description}"
}

# verify_command - Check if a command exists in PATH
# Arguments:
#   $1 - Command name to verify
# Returns:
#   0 - Command exists
#   1 - Command not found
function verify_command() {
	local cmd="${1}"
	if ! command -v "${cmd}" &> /dev/null; then
		log_error "Required command '${cmd}' not found"
		return 1
	fi
	log_debug "Verified command: ${cmd}"
	return 0
}

# ============================================================================
# Installation Functions
# ============================================================================

# install_required_tools - Install all required tools for PowerVC installation
# Description:
#   Downloads and installs PowerVC-Tool, yq-v4, IBM Cloud CLI and plugins,
#   and sets up OpenStack configuration
# Returns:
#   0 - All tools installed successfully
#   1 - Installation failed
# Side Effects:
#   - Modifies PATH to include /tmp/bin
#   - Sets HOME to /tmp
#   - Creates ~/.config/openstack/ directory
#   - Installs tools in /tmp/bin
# Environment:
#   SECRETS_DIR - Directory containing clouds.yaml and certificates
function install_required_tools() {
	log_info "Installing required tools..."

	# Set up environment - use pushd/popd for better directory management
	if ! pushd /tmp > /dev/null; then
		log_error "Failed to change to /tmp directory"
		return 1
	fi

	# Set HOME to /tmp for tool installations
	HOME=/tmp
	export HOME

	# Create bin directory and add to PATH
	if ! mkdir -p /tmp/bin; then
		log_error "Failed to create /tmp/bin directory"
		popd > /dev/null || true
		return 1
	fi

	PATH="/tmp/bin:${PATH}"
	export PATH

	# Install PowerVC-Tool
	local machine
	machine="$(uname -m)"
	[[ "${machine}" == "x86_64" ]] && machine="amd64"

	local tool_bin="ocp-ipi-powervc-linux-${machine}"
	local powervc_url="https://github.com/IBM/ocp-ipi-powervc/releases/download/${POWERVC_TOOL_VERSION}/${tool_bin}"
	download_tool "${powervc_url}" "/tmp/bin/PowerVC-Tool" "PowerVC-Tool ${POWERVC_TOOL_VERSION}"

	# Install yq-v4 if not present
	if ! command -v yq-v4 &> /dev/null; then
		log_info "Installing yq-v4 version ${YQ_VERSION}"
		local yq_arch
		yq_arch="$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')"
		local yq_url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${yq_arch}"
		download_tool "${yq_url}" "/tmp/bin/yq-v4" "yq-v4 ${YQ_VERSION}"
	else
		log_info "yq-v4 already installed"
	fi

	# Install IBM Cloud CLI
	local ibmcloud_tarball="/tmp/IBM_CLOUD_CLI_amd64.tar.gz"

	if [[ ! -f "${ibmcloud_tarball}" ]]; then
		log_info "Installing IBM Cloud CLI version ${IBMCLOUD_VERSION}"
		local ibmcloud_url="https://download.clis.cloud.ibm.com/ibm-cloud-cli/${IBMCLOUD_VERSION}/IBM_Cloud_CLI_${IBMCLOUD_VERSION}_amd64.tar.gz"

		retry_command 3 5 "Download IBM Cloud CLI" \
			curl --fail --location --output "${ibmcloud_tarball}" "${ibmcloud_url}"

		if ! tar xzf "${ibmcloud_tarball}" -C /tmp; then
			log_error "Failed to extract IBM Cloud CLI tarball"
			popd > /dev/null || true
			return 1
		fi

		if [[ ! -f /tmp/Bluemix_CLI/bin/ibmcloud ]]; then
			log_error "/tmp/Bluemix_CLI/bin/ibmcloud does not exist after extraction"
			return 1
		fi

		# Verify signature
		log_info "Verifying IBM Cloud CLI signature..."
		local pubkey_url="https://ibmcloud-cli-installer-public-keys.s3.us.cloud-object-storage.appdomain.cloud/ibmcloud-cli.pub"
		retry_command 3 5 "Download IBM Cloud CLI public key" \
			curl --fail --output /tmp/ibmcloud-cli.pub "${pubkey_url}"

		pushd /tmp/Bluemix_CLI/bin/ > /dev/null || return 1
		if ! openssl dgst -sha256 -verify /tmp/ibmcloud-cli.pub -signature ibmcloud.sig ibmcloud; then
			log_error "IBM Cloud CLI signature verification failed"
			popd > /dev/null || true
			return 1
		fi
		popd > /dev/null || return 1
		log_info "IBM Cloud CLI signature verified successfully"

		PATH="/tmp/Bluemix_CLI/bin:${PATH}"
		export PATH

		# Verify installation
		if command -v file &> /dev/null; then
			file /tmp/Bluemix_CLI/bin/ibmcloud
		fi

		log_info "Checking ibmcloud version..."
		if ! ibmcloud --version; then
			log_error "IBM Cloud CLI is not working properly"
			return 1
		fi
	else
		log_info "IBM Cloud CLI already downloaded"
		PATH="/tmp/Bluemix_CLI/bin:${PATH}"
		export PATH
	fi

	# Install IBM Cloud plugins
	log_info "Installing IBM Cloud plugins..."
	local plugins=(
		"infrastructure-service"
		"power-iaas"
		"cloud-internet-services"
		"cloud-object-storage"
		"dl-cli"
		"dns"
		"tg-cli"
	)

	for plugin in "${plugins[@]}"; do
		log_info "Installing plugin: ${plugin}"
		if ! ibmcloud plugin install "${plugin}" -f; then
			log_warn "Failed to install plugin: ${plugin}"
		fi
	done

	log_info "Installed plugins:"
	ibmcloud plugin list

	# Verify critical plugins
	log_info "Verifying critical plugins..."
	local critical_plugins=("cis" "pi")
	for plugin in "${critical_plugins[@]}"; do
		if ! ibmcloud "${plugin}" > /dev/null 2>&1; then
			log_error "Critical plugin '${plugin}' is not installed or not working"
			ls -la "${HOME}/.bluemix/" || true
			ls -la "${HOME}/.bluemix/plugins/" || true
			return 1
		fi
		log_info "Verified plugin: ${plugin}"
	done

	# Set up OpenStack configuration
	log_info "Setting up OpenStack configuration..."
	mkdir -p "${HOME}/.config/openstack/"

	if [[ ! -f "${SECRETS_DIR}/clouds.yaml" ]]; then
		log_error "clouds.yaml not found in ${SECRETS_DIR}"
		return 1
	fi

	cp "${SECRETS_DIR}/clouds.yaml" "${HOME}/.config/openstack/"
	cp "${SECRETS_DIR}/clouds.yaml" "${HOME}/"
	cp "${SECRETS_DIR}/ocp-ci-ca.pem" "${HOME}/"
	log_info "OpenStack configuration copied successfully"

	# Verify all required tools
	log_info "Verifying all required tools..."
	local -a required_tools
	required_tools=("PowerVC-Tool" "jq" "yq-v4" "openstack")
	for tool in "${required_tools[@]}"; do
		verify_command "${tool}" || return 1
	done

	log_info "All required tools installed and verified successfully"

	# Return to original directory
	popd > /dev/null || true
	return 0
}

# populate_artifact_dir - Copy logs and artifacts to artifact directory
# Description:
#   Copies log bundles and installation logs to ARTIFACT_DIR,
#   redacting sensitive information like passwords and tokens
# Returns:
#   None (always succeeds, logs warnings on failures)
# Side Effects:
#   - Copies files to ARTIFACT_DIR
#   - Creates redacted versions of log files
# Environment:
#   DIR - Installation directory
#   ARTIFACT_DIR - Target directory for artifacts
#   SHARED_DIR - Directory containing installation stats
function populate_artifact_dir() {
	log_info "Populating artifact directory..."

	# Copy log bundles if they exist
	if compgen -G "${DIR}/log-bundle-*.tar.gz" > /dev/null 2>&1; then
		log_info "Copying log bundle(s)..."
		cp "${DIR}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null || {
			log_warn "Failed to copy some log bundles"
		}
	else
		log_debug "No log bundles found"
	fi

	# Redact sensitive information from logs
	log_info "Redacting sensitive information from logs..."
	local redact_pattern='
		s/password: .*/password: REDACTED/g;
		s/X-Auth-Token.*/X-Auth-Token REDACTED/g;
		s/UserData:.*,/UserData: REDACTED,/g;
		s/apikey["[:space:]:=]+[^"[:space:],}]*/apikey: REDACTED/gI;
		s/token["[:space:]:=]+[^"[:space:],}]*/token: REDACTED/gI;
	'

	if [[ -f "${DIR}/.openshift_install.log" ]]; then
		sed -E "${redact_pattern}" "${DIR}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install.log" || {
			log_warn "Failed to redact .openshift_install.log"
		}
	fi

	if [[ -f "${SHARED_DIR}/installation_stats.log" ]]; then
		sed -E "${redact_pattern}" "${SHARED_DIR}/installation_stats.log" > "${ARTIFACT_DIR}/installation_stats.log" || {
			log_warn "Failed to redact installation_stats.log"
		}
	fi

	log_info "Artifact directory populated successfully"
}

# prepare_next_steps - Prepare artifacts and state for next pipeline steps
# Description:
#   Saves installation exit code, populates artifacts, and copies
#   authentication files to shared directory for subsequent steps
# Arguments:
#   None (uses $? for exit code)
# Returns:
#   None
# Side Effects:
#   - Creates install-status.txt in SHARED_DIR
#   - Copies kubeconfig, kubeadmin-password, and metadata.json to SHARED_DIR
#   - Calls populate_artifact_dir
# Environment:
#   SHARED_DIR - Directory for sharing state between pipeline steps
#   DIR - Installation directory
function prepare_next_steps() {
	local exit_code="${1:-$?}"
	if [[ "${CLEANUP_DONE}" == "true" ]]; then
		return 0
	fi
	CLEANUP_DONE=true
	log_info "Preparing next steps (exit code: ${exit_code})..."

	# Save exit code for must-gather to generate junit
	if [[ -n "${SHARED_DIR:-}" && -d "${SHARED_DIR}" ]]; then
		echo "${exit_code}" > "${SHARED_DIR}/install-status.txt" || true
	fi

	if [[ -n "${DIR:-}" && -d "${DIR}" && -n "${ARTIFACT_DIR:-}" && -d "${ARTIFACT_DIR}" ]]; then
		populate_artifact_dir
	fi

	# Copy auth artifacts to shared dir for next steps
	log_info "Copying required artifacts to shared dir..."
	if [[ -n "${DIR:-}" && -d "${DIR}" && -n "${SHARED_DIR:-}" && -d "${SHARED_DIR}" ]]; then
		local artifact
		for artifact in \
			"${DIR}/auth/kubeconfig" \
			"${DIR}/auth/kubeadmin-password" \
			"${DIR}/metadata.json"; do
			if [[ -f "${artifact}" ]]; then
				cp "${artifact}" "${SHARED_DIR}/" || log_warn "Failed to copy $(basename "${artifact}")"
			else
				log_warn "Missing: $(basename "${artifact}")"
			fi
		done
	fi

	log_info "Finished prepare_next_steps"
}

# log_to_file - Redirect all output to a log file
# Arguments:
#   $1 - Path to log file
# Returns:
#   None
# Side Effects:
#   - Redirects STDOUT and STDERR to specified file
#   - Removes existing log file if present
# Warning:
#   This function permanently redirects output for the current shell
function log_to_file() {
	local log_file="${1}"

	log_info "Redirecting output to ${log_file}"

	# Remove existing log file
	rm -f "${log_file}"

	# Close STDOUT and STDERR file descriptors
	exec 1<&-
	exec 2<&-

	# Open STDOUT as log file for read and write
	exec 1<>"${log_file}"

	# Redirect STDERR to STDOUT
	exec 2>&1
}

# init_ibmcloud - Initialize and login to IBM Cloud CLI
# Description:
#   Logs into IBM Cloud using API key and targets us-south region
# Returns:
#   0 - Login successful or already logged in
#   1 - Login failed
#   2 - IBMCLOUD_API_KEY not set
# Side Effects:
#   - Sets IC_API_KEY environment variable
#   - Authenticates with IBM Cloud
#   - Targets us-south region
# Environment:
#   IBMCLOUD_API_KEY - IBM Cloud API key (required)
function init_ibmcloud() {
	log_info "Initializing IBM Cloud CLI..."

	if [[ -z "${IBMCLOUD_API_KEY:-}" ]]; then
		log_error "IBMCLOUD_API_KEY is not set"
		return 2
	fi

	# Set IC_API_KEY for IBM Cloud plugins
	IC_API_KEY="${IBMCLOUD_API_KEY}"
	export IC_API_KEY

	# Check if already logged in
	if ibmcloud iam oauth-tokens &>/dev/null; then
		log_info "Already logged in to IBM Cloud"
		return 0
	fi

	log_info "Logging in to IBM Cloud..."
	# Use --no-region to avoid region-specific login issues, then target region separately
	if ! ibmcloud login --apikey "${IBMCLOUD_API_KEY}" --no-region; then
		log_error "Failed to login to IBM Cloud"
		return 1
	fi

	# Target us-south region
	if ! ibmcloud target -r us-south; then
		log_warn "Failed to target us-south region, continuing anyway"
	fi

	log_info "IBM Cloud CLI initialized successfully"
	return 0
}

# check_resources - Check and optionally destroy existing resources
# Description:
#   Placeholder function for resource checking logic
#   Currently always calls destroy_resources
# Returns:
#   None
# Side Effects:
#   Calls destroy_resources function
# Note:
#   This function is currently not used in the main flow
function check_resources() {
	log_info "Checking resources phase initiated"

	local flag_destroy_resources=false

	log_info "FLAG_DESTROY_RESOURCES=${flag_destroy_resources}"
	if [[ "${flag_destroy_resources}" == "true" ]]; then
		destroy_resources
	fi
}

# hack_cleanup_containers - Clean up OpenStack containers one at a time
# Description:
#   Workaround for bulk deletion errors. Deletes objects and containers
#   individually for the current cluster
# Returns:
#   0 - Cleanup completed (may have warnings)
#   1 - CLOUD variable not set
# Side Effects:
#   - Deletes OpenStack objects and containers matching CLUSTER_NAME
# Environment:
#   CLOUD - OpenStack cloud name from clouds.yaml (required)
#   CLUSTER_NAME - Name of cluster to clean up (required)
# Note:
#   Uses subshell to avoid affecting parent shell environment
function hack_cleanup_containers() {
	log_info "HACK: Cleaning up containers one at a time (workaround for bulk deletion errors)"

	# Validate CLOUD variable
	if [[ -z "${CLOUD:-}" ]]; then
		log_error "CLOUD variable is not set"
		return 1
	fi

	# Use subshell to avoid affecting parent shell
	(
		local container_count=0
		while IFS= read -r container; do
			[[ -z "${container}" ]] && continue

			log_info "Processing container: ${container}"
			container_count=$((container_count + 1))

			# Delete objects in container
			local object_count=0
			while IFS= read -r object; do
				[[ -z "${object}" ]] && continue

				log_debug "Deleting OpenStack Object: ${object}"
				if ! openstack --os-cloud="${CLOUD}" object delete "${container}" "${object}" 2>/dev/null; then
					log_warn "Failed to delete object: ${object}"
				else
					object_count=$((object_count + 1))
				fi
			done < <(openstack --os-cloud="${CLOUD}" object list "${container}" --format csv 2>/dev/null | sed -e '/\(Name\)/d' -e 's,",,g' || true)

			log_info "Deleted ${object_count} objects from container: ${container}"

			# Delete container
			log_info "Deleting OpenStack container: ${container}"
			if ! openstack --os-cloud="${CLOUD}" container delete "${container}" 2>/dev/null; then
				log_warn "Failed to delete container: ${container}"
			fi
		done < <(openstack --os-cloud="${CLOUD}" container list --format csv 2>/dev/null | sed -e '/\(Name\|container_name\)/d' -e 's,",,g' | grep -F -- "${CLUSTER_NAME}" || true)

		log_info "Processed ${container_count} containers"
	)
}

# destroy_resources - Destroy all cluster resources
# Description:
#   Cleans up containers and runs openshift-install destroy cluster
#   with retries. Creates temporary metadata file for cleanup.
# Returns:
#   0 - Resources destroyed successfully
#   1 - Destruction failed after all retries
# Side Effects:
#   - Calls hack_cleanup_containers
#   - Creates temporary metadata.json in /tmp/ocp-test
#   - Runs openshift-install destroy cluster
#   - Records timestamps in SHARED_DIR
# Environment:
#   CLUSTER_NAME - Name of cluster to destroy (required)
#   CLOUD - OpenStack cloud name (required)
#   SHARED_DIR - Directory for timing information
function destroy_resources() {
	log_info "Destroying resources for cluster: ${CLUSTER_NAME}"

	hack_cleanup_containers

	# Create a fake cluster metadata file for cleanup
	local temp_dir="/tmp/ocp-test"
	mkdir -p "${temp_dir}"

	local metadata_file="${temp_dir}/metadata.json"
	log_info "Creating temporary metadata file: ${metadata_file}"

	cat > "${metadata_file}" << EOF
{"clusterName":"${CLUSTER_NAME}","clusterID":"","infraID":"${CLUSTER_NAME}","powervc":{"cloud":"${CLOUD}","identifier":{"openshiftClusterID":"${CLUSTER_NAME}"}},"featureSet":"","customFeatureSet":null}
EOF

	# Attempt to destroy cluster with retries
	local destroy_succeeded=false
	local max_attempts=3

	for attempt in $(seq 1 ${max_attempts}); do
		log_info "Destroying cluster attempt ${attempt}/${max_attempts}..."
		log_info "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"

		date "+%F %X" > "${SHARED_DIR}/CLUSTER_CLEAR_RESOURCE_START_TIME_${attempt}"

		if openshift-install --dir "${temp_dir}" destroy cluster --log-level=debug; then
			destroy_succeeded=true
			date "+%F %X" > "${SHARED_DIR}/CLUSTER_CLEAR_RESOURCE_END_TIME_${attempt}"
			log_info "Successfully destroyed cluster on attempt ${attempt}"
			break
		fi

		date "+%F %X" > "${SHARED_DIR}/CLUSTER_CLEAR_RESOURCE_END_TIME_${attempt}"
		log_warn "Destroy attempt ${attempt} failed"

		if (( attempt < max_attempts )); then
			log_info "Waiting before retry..."
			sleep 10
		fi
	done

	if ! ${destroy_succeeded}; then
		log_error "Failed to destroy cluster after ${max_attempts} attempts"
		return 1
	fi

	log_info "Resource destruction completed successfully"
	return 0
}

# dump_resources - Dump cluster resource information and run watch-create
# Description:
#   Retrieves CIS CRN, sets up SSH configuration, and runs PowerVC-Tool
#   watch-create to monitor cluster resources
# Returns:
#   0 - Successfully ran watch-create or metadata not found
#   1 - Required variables not set or SSH key not found
# Side Effects:
#   - Creates ~/.ssh directory with proper permissions
#   - May add user entry to /etc/passwd
#   - Runs PowerVC-Tool watch-create
# Environment:
#   DIR - Installation directory containing metadata.json
#   HOME - Home directory for SSH setup
#   CLOUD - OpenStack cloud name (required)
#   SSH_PRIV_KEY_FILE - Path to SSH private key (required)
function dump_resources() {
	log_info "Dumping resources information..."

	# Get CRN for CIS instance
	local crn
	crn=$(ibmcloud cis instances --output JSON 2>/dev/null | jq -r '.[] | select(.name == "ipi-cicd-internet-services").crn' 2>/dev/null || echo "")
	if [[ -n "${crn}" ]]; then
		log_info "CRN=${crn}"
	else
		log_debug "CRN not found or not available"
	fi

	if [[ ! -f "${DIR}/metadata.json" ]]; then
		log_warn "Could not find ${DIR}/metadata.json for watch-create"
		return 0
	fi

	# Fix: Load Balancer SSH known_hosts issue
	log_debug "Setting up SSH known_hosts..."
	mkdir -p "${HOME}/.ssh"
	chmod 700 "${HOME}/.ssh"
	touch "${HOME}/.ssh/known_hosts"
	chmod 600 "${HOME}/.ssh/known_hosts"

	# Fix: No user exists for uid issue
	if ! grep -q ":$(id -u):" /etc/passwd 2>/dev/null; then
		if [[ -w /etc/passwd ]]; then
			log_debug "Adding user entry to /etc/passwd"
			echo "test:x:$(id -u):$(id -u):test:/tmp:/sbin/nologin" >> /etc/passwd
		else
			log_warn "/etc/passwd is not writable, skipping user entry"
		fi
	fi

	# Validate required variables
	if [[ -z "${CLOUD:-}" ]]; then
		log_error "CLOUD variable is not set, skipping watch-create"
		return 1
	fi

	if [[ ! -f "${SSH_PRIV_KEY_FILE:-}" ]]; then
		log_error "SSH private key file not found: ${SSH_PRIV_KEY_FILE:-<not set>}"
		return 1
	fi

	log_info "Running PowerVC-Tool watch-create..."
	if ! PowerVC-Tool \
		watch-create \
		--cloud "${CLOUD}" \
		--baseDomain "ipi-ppc64le.cis.ibm.net" \
		--metadata "${DIR}/metadata.json" \
		--kubeconfig "${DIR}/auth/kubeconfig" \
		--bastionUsername "cloud-user" \
		--bastionRsa "${SSH_PRIV_KEY_FILE}" \
		--shouldDebug false; then
		log_warn "PowerVC-Tool watch-create failed, but continuing"
	fi
}

# ============================================================================
# Signal Handlers
# ============================================================================

# Trap TERM signal to kill all child processes
# This ensures clean shutdown when the script receives SIGTERM
# Trap EXIT and TERM signals to run cleanup
# prepare_next_steps is called on script exit to save artifacts and state
trap 'prepare_next_steps $?' EXIT
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi; trap - EXIT; prepare_next_steps 143; exit 143' TERM

# ============================================================================
# Main Script Execution
# ============================================================================

log_info "Starting PowerVC IPI installation script"

# Workaround: cd to /tmp as clouds.yaml is also there and the installer does
# not search the HOME directory.
cd /tmp/ || {
	log_error "Failed to change directory to /tmp"
	exit 1
}

# Validate required environment variables
log_info "Validating required environment variables..."
required_vars=(
	"OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE"
	"SHARED_DIR"
	"ARTIFACT_DIR"
	"CLUSTER_PROFILE_DIR"
	"JOB_NAME"
	"BUILD_ID"
)

for var in "${required_vars[@]}"; do
	if [[ -z "${!var:-}" ]]; then
		log_error "Required environment variable ${var} is not set"
		exit 2
	fi
	log_debug "${var} is set"
done

log_info "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

# Set up installation directory
DIR=/tmp/installer
export DIR

if ! mkdir -p "${DIR}"; then
	log_error "Failed to create installation directory: ${DIR}"
	exit 1
fi

# Copy install config
if [[ ! -f "${SHARED_DIR}/install-config.yaml" ]]; then
	log_error "install-config.yaml not found in ${SHARED_DIR}"
	exit 2
fi

if ! cp "${SHARED_DIR}/install-config.yaml" "${DIR}/"; then
	log_error "Failed to copy install-config.yaml to ${DIR}"
	exit 1
fi

# Set up secrets directory
export SECRETS_DIR=/var/run/powervc-ipi-cicd-secrets/powervc-creds
if [[ ! -d "${SECRETS_DIR}" ]]; then
	log_error "${SECRETS_DIR} directory does not exist!"
	exit 2
fi

log_debug "Secrets directory contents:"
ls -l "${SECRETS_DIR}/" || true

# Load IBM Cloud API key
if [[ ! -f "${SECRETS_DIR}/IBMCLOUD_API_KEY" ]]; then
	log_error "IBMCLOUD_API_KEY file not found in ${SECRETS_DIR}"
	exit 2
fi

IBMCLOUD_API_KEY=$(cat "${SECRETS_DIR}/IBMCLOUD_API_KEY")
if [[ -z "${IBMCLOUD_API_KEY}" ]]; then
	log_error "IBMCLOUD_API_KEY is empty"
	exit 2
fi

install_required_tools

# Load PowerVC configuration
log_info "Loading PowerVC configuration from ${SHARED_DIR}/powervc-conf.yaml"
if [[ ! -f "${SHARED_DIR}/powervc-conf.yaml" ]]; then
	log_error "powervc-conf.yaml not found in ${SHARED_DIR}"
	exit 2
fi

# Read configuration values with validation
ARCH=$(yq-v4 eval '.ARCH' "${SHARED_DIR}/powervc-conf.yaml")
BASE_DOMAIN=$(yq-v4 eval '.BASE_DOMAIN' "${SHARED_DIR}/powervc-conf.yaml")
BRANCH=$(yq-v4 eval '.BRANCH' "${SHARED_DIR}/powervc-conf.yaml")
CLOUD=$(yq-v4 eval '.CLOUD' "${SHARED_DIR}/powervc-conf.yaml")
CLUSTER_NAME=$(yq-v4 eval '.CLUSTER_NAME' "${SHARED_DIR}/powervc-conf.yaml")
COMPUTE_NODE_TYPE=$(yq-v4 eval '.COMPUTE_NODE_TYPE' "${SHARED_DIR}/powervc-conf.yaml")
BASTION_FLAVOR=$(yq-v4 eval '.BASTION_FLAVOR' "${SHARED_DIR}/powervc-conf.yaml")
CLUSTER_FLAVOR=$(yq-v4 eval '.CLUSTER_FLAVOR' "${SHARED_DIR}/powervc-conf.yaml")
LEASED_RESOURCE=$(yq-v4 eval '.LEASED_RESOURCE' "${SHARED_DIR}/powervc-conf.yaml")
NETWORK_NAME=$(yq-v4 eval '.NETWORK_NAME' "${SHARED_DIR}/powervc-conf.yaml")
SERVER_IP=$(yq-v4 eval '.SERVER_IP' "${SHARED_DIR}/powervc-conf.yaml")

# Validate critical configuration values
if [[ -z "${CLOUD}" || "${CLOUD}" == "null" ]]; then
	log_error "CLOUD is not set in powervc-conf.yaml"
	exit 2
fi

if [[ -z "${CLUSTER_NAME}" || "${CLUSTER_NAME}" == "null" ]]; then
	log_error "CLUSTER_NAME is not set in powervc-conf.yaml"
	exit 2
fi

# Export configuration
export IBMCLOUD_API_KEY
export ARCH
export BASE_DOMAIN
export BRANCH
export CLOUD
export CLUSTER_NAME
export COMPUTE_NODE_TYPE
export BASTION_FLAVOR
export CLUSTER_FLAVOR
export LEASED_RESOURCE
export NETWORK_NAME

# Set up additional required paths
export SSH_PRIV_KEY_FILE="${SECRETS_DIR}/ssh-privatekey"
export PULL_SECRET_PATH="${CLUSTER_PROFILE_DIR}/pull-secret"
export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME}/${BUILD_ID}"

# Validate SSH key exists
if [[ ! -f "${SSH_PRIV_KEY_FILE}" ]]; then
	log_error "SSH private key not found: ${SSH_PRIV_KEY_FILE}"
	exit 2
fi

# Validate pull secret exists
if [[ ! -f "${PULL_SECRET_PATH}" ]]; then
	log_error "Pull secret not found: ${PULL_SECRET_PATH}"
	exit 2
fi

log_info "Configuration loaded successfully:"
log_info "  ARCH=${ARCH}"
log_info "  BRANCH=${BRANCH}"
log_info "  LEASED_RESOURCE=${LEASED_RESOURCE}"
log_info "  CLUSTER_NAME=${CLUSTER_NAME}"
log_info "  CLOUD=${CLOUD}"

init_ibmcloud

# NOTE: If you want to test against a certain release, then do something like:
# if echo ${BRANCH} | awk -F. '{ if (($1 == 4) && ($2 == 19)) { exit 0 } else { exit 1 } }' && [ "${ARCH}" == "ppc64le" ]

#
# Don't call check_resources.  Always call destroy_resources since it is safe.
#
destroy_resources

# Move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
log_info "Setting up SSH keys for installer..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Copy all files from cluster profile to ~/.ssh
if ! cp "${CLUSTER_PROFILE_DIR}"/* ~/.ssh/ 2>/dev/null; then
	log_warn "Failed to copy some files from ${CLUSTER_PROFILE_DIR} to ~/.ssh/"
fi

# Record installation start time
date "+%s" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"

# Display openshift-install version
log_info "OpenShift installer version:"
openshift-install version

# Create ignition configs
log_info "Creating ignition configs..."
log_info "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"
if ! openshift-install --dir="${DIR}" create ignition-configs; then
	log_error "Failed to create ignition configs"
	exit 3
fi

# Create installation manifests
log_info "Creating installation manifests..."
log_info "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"
if ! openshift-install --dir="${DIR}" create manifests; then
	log_error "Failed to create manifests"
	exit 3
fi

# Remove channel from CVO overrides if it exists
if [[ -f "${DIR}/manifests/cvo-overrides.yaml" ]]; then
	sed -i '/^  channel:/d' "${DIR}/manifests/cvo-overrides.yaml"
fi

# Sets up the chrony machineconfig for the worker nodes
CHRONY_WORKER_YAML="${SHARED_DIR}/99-chrony-worker.yaml"
if [ -f "${CHRONY_WORKER_YAML}" ]; then
  echo "Saving ${CHRONY_WORKER_YAML} to the install directory..."
  cp "${CHRONY_WORKER_YAML}" "${DIR}/manifests"
fi

# Sets up the chrony machineconfig for the master nodes
CHRONY_MASTER_YAML="${SHARED_DIR}/99-chrony-master.yaml"
if [ -f "${CHRONY_MASTER_YAML}" ]; then
  echo "Saving ${CHRONY_MASTER_YAML} to the install directory..."
  cp "${CHRONY_MASTER_YAML}" "${DIR}/manifests"
fi

# Copy additional manifests from SHARED_DIR
log_info "Checking for additional manifests in ${SHARED_DIR}..."
if find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print -quit | grep -q .; then
	log_info "Found additional manifests:"
	find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \)

	while IFS= read -r -d '' item; do
		manifest="$(basename "${item}")"
		target_name="${manifest##manifest_}"
		log_debug "Copying ${manifest} to ${DIR}/manifests/${target_name}"
		cp "${item}" "${DIR}/manifests/${target_name}"
	done < <(find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)
else
	log_debug "No additional manifests found"
fi

# Copy TLS files from SHARED_DIR
log_info "Checking for TLS files in ${SHARED_DIR}..."
if find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \) -print -quit | grep -q .; then
	log_info "Found TLS files:"
	find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \)

	mkdir -p "${DIR}/tls"
	while IFS= read -r -d '' item; do
		manifest="$(basename "${item}")"
		target_name="${manifest##tls_}"
		log_debug "Copying ${manifest} to ${DIR}/tls/${target_name}"
		cp "${item}" "${DIR}/tls/${target_name}"
	done < <(find "${SHARED_DIR}" \( -name "tls_*.key" -o -name "tls_*.pub" \) -print0)
else
	log_debug "No TLS files found"
fi

# Record cluster installation start time
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"

# Send metadata if it exists
if [[ -f "${DIR}/metadata.json" ]]; then
	log_info "Sending metadata.json to server"
	if PowerVC-Tool \
		send-metadata \
		--createMetadata "${DIR}/metadata.json" \
		--serverIP "${SERVER_IP}" \
		--shouldDebug true; then
		log_info "Metadata sent successfully"
	else
		log_warn "Failed to send metadata, continuing anyway"
	fi

	# Extract and save infraID
	INFRAID=$(jq -r .infraID "${DIR}/metadata.json" 2>/dev/null || echo "")
	if [[ -n "${INFRAID}" && "${INFRAID}" != "null" ]]; then
		log_info "INFRAID=${INFRAID}"
		# Note: powervc-conf.yaml might be read-only, so we ignore errors
		echo "INFRAID: ${INFRAID}" >> "${SHARED_DIR}/powervc-conf.yaml" 2>/dev/null || \
			log_debug "Could not write INFRAID to powervc-conf.yaml (read-only filesystem)"
	fi
else
	log_warn "Could not find ${DIR}/metadata.json for send-metadata"
fi

# Create cluster
log_info "========================================================================"
log_info "BEGIN: Creating OpenShift cluster"
log_info "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"
log_info "========================================================================"

set +e  # Don't exit on error, we want to handle it
openshift-install --dir="${DIR}" create cluster 2>&1 | grep --line-buffered -vi 'password\|X-Auth-Token\|UserData:\|apikey\|token'
ret=${PIPESTATUS[0]}
set -e

log_info "========================================================================"
log_info "END: Creating OpenShift cluster (exit code: ${ret})"
log_info "========================================================================"

# Determine if we need to wait for install-complete
SKIP_WAIT_FOR=false
if [[ ${ret} -eq 0 ]]; then
	SKIP_WAIT_FOR=true
	log_info "Cluster creation completed successfully"
else
	log_warn "Cluster creation failed with exit code ${ret}, will try wait-for install-complete"
fi

# Wait for installation to complete if needed
if ! ${SKIP_WAIT_FOR}; then
	log_info "========================================================================"
	log_info "BEGIN: Waiting for installation to complete"
	log_info "DATE=$(date --utc '+%Y-%m-%dT%H:%M:%S%:z')"
	log_info "========================================================================"

	set +e
	openshift-install wait-for install-complete --dir="${DIR}" 2>&1 | grep --line-buffered -vi 'password\|X-Auth-Token\|UserData:\|apikey\|token'
	ret=${PIPESTATUS[0]}
	set -e

	log_info "========================================================================"
	log_info "END: Waiting for installation to complete (exit code: ${ret})"
	log_info "========================================================================"
fi

# Record installation end time
date "+%s" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

# Dump resources information
dump_resources

# Extract installation statistics
log_info "Extracting installation statistics..."
if [[ -f "${DIR}/.openshift_install.log" ]]; then
	grep -E '(Creation complete|level=error|: [0-9ms]*")' "${DIR}/.openshift_install.log" > "${SHARED_DIR}/installation_stats.log" || \
		log_warn "Failed to extract installation statistics"
else
	log_warn "Installation log not found: ${DIR}/.openshift_install.log"
fi

# Handle success case
if [[ ${ret} -eq 0 ]]; then
	log_info "Installation completed successfully!"
	touch "${SHARED_DIR}/success"

	# Save console URL for ci-chat-bot
	if [[ -f "${DIR}/auth/kubeconfig" ]]; then
		log_info "Retrieving console URL..."
		console_url=$(env KUBECONFIG="${DIR}/auth/kubeconfig" oc -n openshift-console get routes console -o=jsonpath='{.spec.host}' 2>/dev/null || echo "")
		if [[ -n "${console_url}" ]]; then
			echo "https://${console_url}" > "${SHARED_DIR}/console.url"
			log_info "Console URL: https://${console_url}"
		else
			log_warn "Failed to retrieve console URL"
		fi
	else
		log_warn "Kubeconfig not found, cannot retrieve console URL"
	fi
else
	log_error "Installation failed with exit code ${ret}"
fi

log_info "Script execution completed with exit code ${ret}"
exit "${ret}"
