#!/bin/bash

# Exit on errors, unset variables, and failed pipelines.
set -o nounset
set -o errexit
set -o pipefail

# PowerVC helper release to download for this step.
readonly POWERVC_TOOL_VERSION="v2.4.6"

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
# Log a final failure message when the script exits non-zero.
# Arguments:
#   Exit code.
#######################################
function cleanup_on_exit() {
        local rc="${1:-0}"
        if [[ "${rc}" -eq 0 ]]; then
                return 0
        fi

        log_warning "PowerVC checks failed with exit code ${rc}"
}

# Emit a final failure message for any non-zero script exit.
trap 'cleanup_on_exit $?' EXIT

#######################################
# Ensure required environment variables are present before running checks.
# Globals:
#   CLOUD
# Returns:
#   0 on success; exits on failure.
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
		exit 1
	fi

	log_info "All required environment variables are set"
}

#######################################
# Download the helper binaries required by this step into /tmp/bin.
# Globals:
#   HOME
#   PATH
# Returns:
#   0 on success; exits on failure.
#######################################
function install_required_tools() {
	log_info "Installing required tools..."

	local tmp_bin_dir="/tmp/bin"

	cd /tmp || {
		log_error "Failed to change directory to /tmp"
		exit 1
	}

	# Make a private directory that is only readable by us
	HOME="$(mktemp -d /tmp/powervc-checks.XXXXXX)"
	chmod 0700 "${HOME}"
	echo "HOME is now ${HOME}"
	export HOME

	mkdir -p "${tmp_bin_dir}" || {
		log_error "Failed to create ${tmp_bin_dir} directory"
		exit 1
	}

	PATH="${tmp_bin_dir}:${PATH}"
	echo "PATH is now ${PATH}"
	export PATH

	log_info "Installing PowerVC-Tool version ${POWERVC_TOOL_VERSION}"
	local machine
	machine=$(uname -m)
	case "${machine}" in
		x86_64)
			machine="amd64"
			;;
		ppc64le|amd64)
			;;
		*)
			log_error "Unsupported architecture: ${machine}"
			exit 1
			;;
	esac

	local tool_url="https://github.com/IBM/ocp-ipi-powervc/releases/download/${POWERVC_TOOL_VERSION}"
	local -a tools
	tools=(
		"ocp-ipi-powervc-linux-${machine}:ocp-ipi-powervc"
		"print-stream-json.sh:print-stream-json.sh"
	)
	local tool
	local source_name
	local destination_name

	for tool in "${tools[@]}"; do
		source_name="${tool%%:*}"
		destination_name="${tool#*:}"
		log_info "Downloading tool: ${source_name}"
		if ! curl --location --fail --silent \
			--connect-timeout 30 --max-time 300 --show-error \
			--output "${tmp_bin_dir}/${destination_name}" \
			"${tool_url}/${source_name}"; then
			log_error "Failed to download ${source_name}"
			exit 1
		fi
		chmod ugo+x "${tmp_bin_dir}/${destination_name}"
	done

	# Setup OpenStack configuration
	log_info "Setting up OpenStack credentials..."
	mkdir -p "${HOME}/.config/openstack/" || {
		log_error "Failed to create OpenStack config directory"
		exit 1
	}

	if [[ ! -f "${SECRETS_DIR}/clouds.yaml" ]]; then
		log_error "clouds.yaml not found at ${SECRETS_DIR}/clouds.yaml"
		exit 1
	fi

	if [[ ! -f "${SECRETS_DIR}/ocp-ci-ca.pem" ]]; then
		log_error "ocp-ci-ca.pem not found at ${SECRETS_DIR}/ocp-ci-ca.pem"
		exit 1
	fi

	install -m 0600 "${SECRETS_DIR}/clouds.yaml" "${HOME}/.config/openstack/clouds.yaml" || {
		log_error "Failed to copy clouds.yaml to .config/openstack/"
		exit 1
	}

	install -m 0600 "${SECRETS_DIR}/clouds.yaml" "${HOME}/clouds.yaml" || {
		log_error "Failed to copy clouds.yaml to HOME"
		exit 1
	}

	install -m 0600 "${SECRETS_DIR}/ocp-ci-ca.pem" "${HOME}/ocp-ci-ca.pem" || {
		log_error "Failed to copy ocp-ci-ca.pem"
		exit 1
	}

	# The cloud configuration in the secret uses hardcoded /tmp/ocp-ci-ca.pem
	sed -i -e "s|/tmp/ocp-ci-ca.pem|${HOME}/ocp-ci-ca.pem|" "${HOME}/clouds.yaml"
	sed -i -e "s|/tmp/ocp-ci-ca.pem|${HOME}/ocp-ci-ca.pem|" "${HOME}/.config/openstack/clouds.yaml"

	# Verify all required tools are available
	log_info "Verifying installed tools..."
	local tools=("ocp-ipi-powervc" "openstack")
	for tool in "${tools[@]}"; do
		if ! command -v "${tool}" &>/dev/null; then
			log_error "Required tool '${tool}' is not available"
			exit 1
		fi
		log_info "✓ ${tool} is available at $(command -v "${tool}")"
	done

	log_info "All required tools installed successfully"
}

#######################################
# Verify that RHCOS stream data exists for each supported release/RHEL pair.
#######################################
function check_rhcos_images() {
	local -a releases
	local -a rhels
	# @TODO make global.  Programmatically determine list of releases.
	releases=("release-4.21" "release-4.22" "release-4.23" "release-5.0")
	rhels=("rhel9" "rhel10")

	log_info "Checking RHCOS images for cloud ${CLOUD}"
	for rhel in "${rhels[@]}"; do
		for release in "${releases[@]}"; do
			log_info "Checking ${release} ${rhel}"
			print-stream-json.sh --cloud "${CLOUD}" --release "${release}" --rhel "${rhel}"
		done
	done
}

#######################################
# Run environment validation, install helper tools, and execute checks.
#######################################
function main() {
	log_info "=== PowerVC Checks Script Started ==="

	# Setup secrets directory
	export SECRETS_DIR=/var/run/powervc-ipi-cicd-secrets/powervc-creds
	if [[ ! -d "${SECRETS_DIR}" ]]; then
		log_error "Secrets directory does not exist: ${SECRETS_DIR}"
		exit 1
	fi

	# Validate required inputs.
	validate_environment

	# Download helper binaries.
	install_required_tools

	# Execute the image checks.
	check_rhcos_images

	log_info "=== PowerVC Checks Script Completed ==="
}

main
