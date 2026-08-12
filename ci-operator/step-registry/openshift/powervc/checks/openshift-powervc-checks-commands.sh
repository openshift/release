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
# Confirm that all environment variables required by the checks step are
# non-empty before any work begins.
#
# The function iterates over a list of required variable names and collects
# any that are unset or empty. If any are missing it logs the full list and
# exits immediately, preventing downstream functions from running with an
# incomplete configuration.
#
# Currently required variables:
#   CLOUD – name of the target OpenStack/PowerVC cloud passed to
#           ocp-ipi-powervc and print-stream-json.sh.
#
# Globals:
#   CLOUD – (in) must be non-empty; validated but not modified.
# Returns:
#   0 if all required variables are set; exits non-zero listing every missing
#   variable if any are absent.
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
# Download helper binaries, configure a private HOME directory, and install
# OpenStack credentials so subsequent steps can reach the PowerVC cloud.
#
# The function performs the following steps in order:
#   1. Changes to /tmp and creates a private, mode-0700 HOME directory under
#      /tmp/powervc-checks.XXXXXX so secrets written there are not world-
#      readable.
#   2. Creates /tmp/bin and prepends it to PATH.
#   3. Detects the host architecture (x86_64 → amd64, ppc64le stays as-is)
#      and downloads the matching ocp-ipi-powervc binary together with
#      print-stream-json.sh from the GitHub release at POWERVC_TOOL_VERSION.
#      Each download is retried up to 10 times with a progressive back-off
#      (attempt × 5 seconds) before the function exits non-zero.
#   4. Copies clouds.yaml (to both $HOME and $HOME/.config/openstack/) and
#      ocp-ci-ca.pem from SECRETS_DIR, then rewrites any hardcoded
#      /tmp/ocp-ci-ca.pem path in both copies to the real $HOME path.
#   5. Verifies that ocp-ipi-powervc and openstack are resolvable on PATH.
#
# Globals:
#   POWERVC_TOOL_VERSION – (in)  GitHub release tag used to build the download
#                                URL.
#   SECRETS_DIR          – (in)  directory containing clouds.yaml and
#                                ocp-ci-ca.pem mounted from the CI secret.
#   HOME                 – (out) overwritten with the newly created private
#                                temp directory.
#   PATH                 – (out) /tmp/bin prepended so downloaded tools are
#                                found first.
# Returns:
#   0 on success; exits non-zero if any download (after all retries), copy,
#   or tool-check fails.
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

	local max_attempts=10
	local attempt

	for tool in "${tools[@]}"; do
		source_name="${tool%%:*}"
		destination_name="${tool#*:}"
		log_info "Downloading tool: ${source_name}"
		for (( attempt=1; attempt<=max_attempts; attempt++ )); do
			if curl --location --fail --silent \
				--connect-timeout 30 --max-time 300 --show-error \
				--output "${tmp_bin_dir}/${destination_name}" \
				"${tool_url}/${source_name}"; then
				break
			fi
			log_warning "Download attempt ${attempt}/${max_attempts} failed for ${source_name}"
			if (( attempt == max_attempts )); then
				log_error "Failed to download ${source_name} after ${max_attempts} attempts"
				exit 1
			fi
			# A progressive back-off of sleep is applied between retries to avoid hammering the server.
			sleep $(( attempt * 5 ))
		done
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
# Query the OpenShift CI release-stream API and populate the global RELEASES
# array with every supported major.minor version.
#
# The function:
#   1. Fetches all release-stream tags from the ppc64le CI endpoint.
#   2. Extracts the major.minor prefix (e.g. "4.21") from each tag name.
#   3. Deduplicates the resulting list.
#   4. Filters out versions older than 4.21.
#   5. Sorts the remaining versions numerically (so 4.9 < 4.10).
#
# Globals:
#   RELEASES  – (out) indexed array of "major.minor" version strings.
# Returns:
#   0 on success; inherits any curl/jq non-zero exit on failure.
#######################################
function find_openshift_releases() {
	log_info "Finding OpenShift releases"

	# Capture jq output into a bash array using read -a to avoid word-splitting
	# issues with glob characters that RELEASES=($(…)) is susceptible to.
	# Note: The first PowerVC supported release is 4.21.
	IFS=$'\n' read -r -d '' -a RELEASES < <(
		curl --silent --connect-timeout 30 --max-time 120 \
			https://ppc64le.ocp.releases.ci.openshift.org/api/v1/releasestreams/all | \
		jq -r '
	   # 1. Flatten: collect all tag name strings from every stream into one array
	   [.[] | .[]?]

	   # 2. Extract major.minor: use regex to capture only the "x.y" prefix from each tag
	   | map(capture("^(?<v>[0-9]+\\.[0-9]+)") | .v)

	   # 3. Deduplicate: remove repeated "x.y" values
	   | unique

	   # 4. Filter: keep only versions >= 4.21
	   #    - split "4.21" into ["4","21"], convert to [4,21]
	   #    - keep if major > 4, or major == 4 and minor >= 21
	   | map(select(
	       split(".") | map(tonumber)
	       | .[0] > 4 or (.[0] == 4 and .[1] >= 21)
	     ))

	   # 5. Sort numerically: split and convert to numbers so 4.9 < 4.10
	   | sort_by(split(".") | map(tonumber))

	   # 6. Unwraps the array so each version prints on its own line
	   | .[]
	 '
	) || true
	export RELEASES

	if (( ${#RELEASES[@]} == 0 )); then
		log_error "Could not any releases?"
		return 1
	fi

	log_info "Found ${#RELEASES[@]} releases"
	log_info "First: ${RELEASES[0]}, Last: ${RELEASES[-1]}"
}

#######################################
# Verify that RHCOS stream data is available for every supported OpenShift
# release and RHEL generation on the target PowerVC cloud.
#
# For each combination of RHEL version (rhel9, rhel10) and every entry in the
# global RELEASES array, the function invokes print-stream-json.sh to confirm
# that a corresponding RHCOS image stream entry exists.
#
# Globals:
#   CLOUD    – (in) name of the target OpenStack/PowerVC cloud.
#   RELEASES – (in) indexed array of "major.minor" OpenShift version strings,
#              populated by find_openshift_releases.
# Returns:
#   0 if all checks pass; non-zero if any print-stream-json.sh invocation fails.
#######################################
function check_rhcos_images() {
	local -a rhels

	rhels=("rhel9" "rhel10")

	log_info "Checking RHCOS images for cloud ${CLOUD}"
	for rhel in "${rhels[@]}"; do
		for release in "${RELEASES[@]}"; do
			log_info "Checking ${release} ${rhel}"
			print-stream-json.sh --cloud "${CLOUD}" --release "release-${release}" --rhel "${rhel}"
		done
	done
}

#######################################
# Entry point for the PowerVC checks step.
#
# Orchestrates the full check sequence in order:
#   1. Resolves and exports SECRETS_DIR; exits if the directory is absent.
#   2. Calls validate_environment to confirm required variables are set.
#   3. Calls install_required_tools to download helper binaries and configure
#      OpenStack credentials.
#   4. Calls find_openshift_releases to populate the RELEASES array.
#   5. Calls check_rhcos_images to verify RHCOS stream data for every
#      supported release/RHEL combination on the target cloud.
#
# Globals:
#   SECRETS_DIR – (out) path to the mounted PowerVC credentials secret.
#   CLOUD       – (in)  validated by validate_environment.
# Returns:
#   0 on success; non-zero (and logs an error) if any step fails.
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

	# Determine the OpenShift PowerVC supported releases
	find_openshift_releases
	
	# Execute the image checks.
	check_rhcos_images

	log_info "=== PowerVC Checks Script Completed ==="
}

main
