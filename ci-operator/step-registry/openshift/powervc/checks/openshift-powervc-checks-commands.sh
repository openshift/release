#!/bin/bash

# Exit on errors, unset variables, and failed pipelines.
set -o nounset
set -o errexit
set -o pipefail

# PowerVC helper release to download for this step.
readonly POWERVC_TOOL_VERSION="v2.4.8"

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
#           PowerVC-Tool and print-stream-json.sh.
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
# Retry a command a fixed number of times with a constant delay between
# attempts.
#
# The function logs every attempt, returns immediately on the first success,
# and emits a final error after the last failure.
#
# Arguments:
#   $1 - Maximum number of attempts.
#   $2 - Delay in seconds between attempts.
#   $3 - Description of the operation for log messages.
#   $@ - Command and arguments to execute after the first three parameters.
# Returns:
#   0 if the command succeeds within the allowed attempts.
#   1 if the command fails on every attempt.
#######################################
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
			log_warning "Failed, retrying in ${delay}s..."
			sleep "${delay}"
		fi
		((attempt++))
	done

	log_error "Failed after ${max_attempts} attempts: ${description}"
	return 1
}

#######################################
# Download a helper binary, optionally verify its SHA256 checksum, and mark it
# executable.
#
# When SHA verification is enabled (the default) the function downloads both the
# target file and its matching .sha256 file, verifies the checksum from the
# target directory, and leaves the executable in place only when verification
# succeeds.  When disabled the SHA download and check are skipped entirely.
#
# Arguments:
#   $1 - Source URL.
#   $2 - Destination path for the downloaded file.
#   $3 - Human-readable description used in log messages.
#   $4 - (optional) Whether to download and verify the SHA256 checksum.
#        Accepts "true" or "false". Defaults to "true".
# Returns:
#   0 if the file is downloaded (and checksum verification passes when enabled).
#   1 if a download fails or checksum verification fails.
# Side Effects:
#   Writes the file and (when enabled) checksum file at the destination path
#   and changes the downloaded file mode.
#######################################
function download_tool_w_sha() {
	local url="${1}"
	local output="${2}"
	local description="${3}"
	local verify_sha="${4:-true}"
	local rc=0

	log_info "Downloading ${description} from ${url}"
	if ! retry_command 3 5 "Download ${description}" \
		curl --fail --location --silent \
			--show-error --connect-timeout 30 --max-time 120 \
			--output "${output}" "${url}"; then
		log_error "Could not download ${url}"
		return 1
	fi

	chmod +x "${output}"

	if [[ "${verify_sha}" == "true" ]]; then
		url="${url}.sha256"
		output="${output}.sha256"
		log_info "Downloading ${description} SHA256 from ${url}"
		if ! retry_command 3 5 "Download ${description} SHA256" \
			curl --fail --location --silent \
				--show-error --connect-timeout 30 --max-time 120 \
				--output "${output}" "${url}"; then
			log_error "Could not download ${url}"
			return 1
		fi

		pushd "$(dirname "${output}")" > /dev/null || {
			log_error "Failed to change directory to $(dirname "${output}")"
			return 1
		}
		if ! sha256sum --check "$(basename "${output}")"; then
			log_error "sha256 sum failed verification"
			rm -f "${output}" "${output%.sha256}"
			popd > /dev/null || true
			return 1
		fi
		popd > /dev/null || rc=$?
	fi

	log_info "Successfully installed ${description}"

	return ${rc}
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
#   5. Verifies that PowerVC-Tool and openstack are resolvable on PATH.
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

	local tool_bin="ocp-ipi-powervc-linux-${machine}"
	local powervc_url="https://github.com/IBM/ocp-ipi-powervc/releases/download/${POWERVC_TOOL_VERSION}/${tool_bin}"
	if ! download_tool_w_sha "${powervc_url}" "${tmp_bin_dir}/${tool_bin}" "${tool_bin} ${POWERVC_TOOL_VERSION}"; then
		log_error "Could not download ${powervc_url}"
		exit 1
	fi
	mv "${tmp_bin_dir}/${tool_bin}" "${tmp_bin_dir}/PowerVC-Tool"

	local print_stream_url="https://github.com/IBM/ocp-ipi-powervc/releases/download/${POWERVC_TOOL_VERSION}/print-stream-json.sh"
	if ! download_tool_w_sha "${print_stream_url}" "${tmp_bin_dir}/print-stream-json.sh" "print-stream-json ${POWERVC_TOOL_VERSION}"; then
		log_error "Could not download ${print_stream_url}"
		exit 1
	fi

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
	local tools=("PowerVC-Tool" "print-stream-json.sh" "openstack")
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
