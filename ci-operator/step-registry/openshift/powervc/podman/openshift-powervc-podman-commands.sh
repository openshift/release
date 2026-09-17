#!/bin/bash

# Exit on errors, unset variables, and failed pipelines.
set -o nounset
set -o errexit
set -o pipefail

# Tools versions...
readonly POWERVC_TOOL_VERSION="v2.4.9"
readonly YQ_VERSION="v4.53.6"
readonly PVCCTL_VERSION="1.0"

# Setup secrets directory
readonly SECRETS_DIR="/var/run/powervc-ipi-cicd-secrets/powervc-creds"

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

        log_warning "PowerVC podman failed with exit code ${rc}"
}

# Emit a final failure message for any non-zero script exit.
trap 'cleanup_on_exit $?' EXIT

#######################################
# Confirm that all environment variables required by the podman step are
# non-empty before any work begins.
#
# The function iterates over a list of required variable names and collects
# any that are unset or empty. If any are missing it logs the full list and
# exits immediately, preventing downstream functions from running with an
# incomplete configuration.
#
# Currently required variables:
#   CLOUD – name of the cloud in clouds.yaml; supplied by the step's env
#           default and validated here for parity with the other PowerVC steps.
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
# Read a required secret file from SECRETS_DIR, failing with a clear message
# if it is missing.
#
# Arguments:
#   $1 - Name of the secret file within SECRETS_DIR.
# Globals:
#   SECRETS_DIR – (in) directory the secret file is read from.
# Outputs:
#   Writes the file contents to stdout.
# Returns:
#   0 on success; exits non-zero if the file does not exist.
#######################################
function read_secret() {
	local name="${1}"
	local path="${SECRETS_DIR}/${name}"

	if [[ ! -f "${path}" ]]; then
		log_error "Required secret file is missing: ${path}"
		exit 1
	fi

	cat "${path}"
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
# Download helper binaries and expose them on PATH so subsequent steps can
# drive the PowerVC cloud.
#
# The function performs the following steps in order:
#   1. Changes to /tmp and creates a private, mode-0700 HOME directory under
#      /tmp/powervc-checks.XXXXXX so anything written there is not world-
#      readable.
#   2. Creates /tmp/bin and prepends it to PATH.
#   3. Detects the host architecture (x86_64 → amd64, ppc64le/amd64 used as-is,
#      anything else is an error) and downloads the matching ocp-ipi-powervc
#      and UploadRhcos binaries from the IBM GitHub release at
#      POWERVC_TOOL_VERSION (with SHA256 verification), then renames them to
#      the stable names PowerVC-Tool and UploadRhcos. Downloads are retried up
#      to 3 times with a constant 5-second delay before the function exits
#      non-zero.
#   4. Installs yq-v4 at YQ_VERSION from the mikefarah/yq GitHub release (no
#      SHA256 verification) unless a yq-v4 is already resolvable on PATH.
#   5. Writes a pvcctl wrapper script into /tmp/bin that runs the
#      quay.io/powercloud/pvcctl:${PVCCTL_VERSION} container.
#   6. Verifies that PowerVC-Tool, UploadRhcos, yq-v4, and pvcctl are
#      resolvable on PATH.
#
# Globals:
#   POWERVC_TOOL_VERSION – (in)  IBM GitHub release tag used to build the
#                                download URL.
#   YQ_VERSION           – (in)  mikefarah/yq release tag for yq-v4.
#   PVCCTL_VERSION       – (in)  tag baked into the generated pvcctl wrapper.
#   HOME                 – (out) overwritten with the newly created private
#                                temp directory.
#   PATH                 – (out) /tmp/bin prepended so downloaded tools are
#                                found first.
# Returns:
#   0 on success; exits non-zero if any download (after all retries) or
#   tool-check fails.
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

	log_info "Downloading PowerVC-Tool version ${POWERVC_TOOL_VERSION}"
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

	log_info "Downloading UploadRhcos version ${POWERVC_TOOL_VERSION}"
	local uploadrhcos_bin="UploadRhcos-linux-${machine}"
	powervc_url="https://github.com/IBM/ocp-ipi-powervc/releases/download/${POWERVC_TOOL_VERSION}/${uploadrhcos_bin}"
	if ! download_tool_w_sha "${powervc_url}" "${tmp_bin_dir}/${uploadrhcos_bin}" "${uploadrhcos_bin} ${POWERVC_TOOL_VERSION}"; then
		log_error "Could not download ${powervc_url}"
		exit 1
	fi
	mv "${tmp_bin_dir}/${uploadrhcos_bin}" "${tmp_bin_dir}/UploadRhcos"

	# Install yq-v4 if not present
	log_info "Checking for yq-v4..."
	local cmd_yq
	cmd_yq="$(command -v yq-v4 2>/dev/null || true)"

	if [[ ! -x "${cmd_yq}" ]]; then
		log_info "Downloading yq-v4 version ${YQ_VERSION}"
		local yq_arch
		yq_arch=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
		local yq_url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${yq_arch}"

		if ! download_tool_w_sha "${yq_url}" "${tmp_bin_dir}/yq-v4" "yq-v4 version ${YQ_VERSION}" "false"; then
			log_error "Could not download ${yq_url}"
			exit 1
		fi
	else
		log_info "yq-v4 already installed at ${cmd_yq}"
	fi

	# Create pvcctl command. The heredoc delimiter is unquoted so PVCCTL_VERSION
	# is baked in now, while \${PWD} and \$@ are escaped to stay literal and
	# resolve when the wrapper runs.
	cat << ___EOF___ > "${tmp_bin_dir}/pvcctl"
#!/bin/bash
podman run --rm -v "\${PWD}:/work:Z" -w /work "quay.io/powercloud/pvcctl:${PVCCTL_VERSION}" "\$@"
___EOF___
	chmod u+x "${tmp_bin_dir}/pvcctl"

	# Verify all required tools are available
	log_info "Verifying installed tools..."
	local tools=("PowerVC-Tool" "UploadRhcos" "yq-v4" "pvcctl")
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
# Install the OpenStack credentials so the PowerVC tools can authenticate.
#
# The function performs the following steps in order:
#   1. Creates ${HOME}/.config/openstack.
#   2. Verifies clouds.yaml and ocp-ci-ca.pem are present in the mounted secret,
#      failing fast if either is missing.
#   3. Installs clouds.yaml (mode 0600) into both ${HOME}/.config/openstack and
#      ${HOME}, and installs ocp-ci-ca.pem (mode 0600) into ${HOME}.
#   4. Rewrites the hardcoded /tmp/ocp-ci-ca.pem path in both clouds.yaml copies
#      to point at the CA file under ${HOME}.
#
# Globals:
#   SECRETS_DIR – (in) directory containing clouds.yaml and ocp-ci-ca.pem
#                      mounted from the CI secret.
#   HOME        – (in) private directory set by install_required_tools; the
#                      OpenStack config is written under it.
# Returns:
#   0 on success; exits non-zero if a required secret is missing or a copy fails.
#######################################
function setup_openstack_config() {
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
}

#######################################
# Generate config.yaml for pvcctl and populate it with credentials from the
# mounted CI secret.
#
# The function performs the following steps in order:
#   1. Changes to /tmp so config.yaml is written to a private, writable path.
#   2. Installs the quay.io registry auth (and points REGISTRY_AUTH_FILE at it)
#      so the pvcctl image can be pulled, then runs
#      `pvcctl image import --gen-config` to emit a config.yaml template into
#      the current directory.
#   3. Fills in the SVC (Storwize/SVC) host, user, and password from the secret
#      files using yq strenv() so special characters are handled safely and the
#      values never appear on the command line.
#   4. Reads the PowerVC auth_url out of the mounted clouds.yaml and writes it
#      to .powervc.url, failing fast if it is missing.
#
# Globals:
#   SECRETS_DIR        – (in)  directory containing quay-io-ci, SVC_* files,
#                              and clouds.yaml mounted from the CI secret.
#   PVCCTL_VERSION     – (in)  tag of the quay.io/powercloud/pvcctl image to run.
#   HOME               – (in)  private directory set by install_required_tools;
#                              used for the containers auth.json location.
#   REGISTRY_AUTH_FILE – (out) set so podman reads the auth.json written above.
# Returns:
#   0 on success; exits non-zero if the pvcctl run fails, config.yaml is not
#   produced, or the PowerVC URL cannot be resolved.
#######################################
function setup_config_yaml() {
	log_info "Setting up config.yaml..."

	cd ${HOME} || {
		log_error "Failed to change directory to ${HOME}"
		exit 1
	}

	# Install the quay.io registry credentials and point podman at them so the
	# pvcctl image can be pulled.
	mkdir -p ${HOME}/.config/containers/
	if [[ ! -f "${SECRETS_DIR}/quay-io-ci" ]]; then
		log_error "Required secret file is missing: ${SECRETS_DIR}/quay-io-ci"
		exit 1
	fi
	install -m 0600 "${SECRETS_DIR}/quay-io-ci" ${HOME}/.config/containers/auth.json
	export REGISTRY_AUTH_FILE="${HOME}/.config/containers/auth.json"

	# Generate the config.yaml template into the current directory (/tmp).
	pvcctl image import --gen-config

	if [ ! -f config.yaml ]; then
		log_error "config.yaml missing after --gen-config"
		exit 1
	fi
	# Log ownership/permissions so container-uid mapping issues are visible.
	ls -l config.yaml || true

	# Populate SVC credentials via strenv() so special characters are safe and
	# the secret values are never passed as command-line arguments.
	SVC_HOST="$(read_secret SVC_HOST)" yq-v4 --inplace '.svc.host = strenv(SVC_HOST)' config.yaml
	SVC_USER="$(read_secret SVC_USER)" yq-v4 --inplace '.svc.user = strenv(SVC_USER)' config.yaml
	SVC_PASSWORD="$(read_secret SVC_PASSWORD)" yq-v4 --inplace '.svc.password = strenv(SVC_PASSWORD)' config.yaml

	# Pull the PowerVC auth URL from the mounted clouds.yaml and record it.
	POWERVC_URL=$(yq-v4 eval '.clouds.ocp-ci.auth.auth_url' "${SECRETS_DIR}/clouds.yaml")
	if [[ -z "${POWERVC_URL}" || "${POWERVC_URL}" == "null" ]]; then
		log_error "POWERVC_URL is empty or null (${POWERVC_URL})?"
		exit 1
	fi
	POWERVC_URL="${POWERVC_URL}" yq-v4 --inplace '.powervc.url = strenv(POWERVC_URL)' config.yaml

	log_info "Done setting up config.yaml..."
}

#######################################
# Upload any missing RHCOS images for the supported releases via UploadRhcos.
#
# Builds the repeated --release arguments from the releases array so the list
# is defined in one place, then invokes UploadRhcos once per RHEL version in
# the rhels array.
#
# Every RHEL version is attempted even if an earlier one fails; the failures
# are collected and reported together, and the function returns non-zero if any
# RHEL version failed.
#
# Returns:
#   0 if UploadRhcos succeeds for every RHEL version; 1 otherwise.
#######################################
function upload_rhcos_images() {
	# Declarations
	local releases=(
		release-4.21
		release-4.22
		release-4.23
		release-5.0
	)
	local rhels=(
		rhel9
		rhel10
	)
	local release_args=()
	local failed=()
	local release
	local rhel

	# Setup required environment variables
	SVC_HOST="$(read_secret SVC_HOST)"
	export SVC_HOST
	PROJECT_UPLOAD="$(read_secret PROJECT_UPLOAD)"
	export PROJECT_UPLOAD
	TEMPLATE="$(read_secret TEMPLATE)"
	export TEMPLATE

	cd ${HOME} || {
		log_error "Failed to change directory to ${HOME}"
		exit 1
	}

	# Build the repeated --release arguments (shared across all RHEL versions).
	for release in "${releases[@]}"; do
		release_args+=(--release "${release}")
	done

	for rhel in "${rhels[@]}"; do
		log_info "Uploading RHCOS images for ${rhel}..."
		if ! UploadRhcos \
			"${release_args[@]}" \
			--rhel "${rhel}" \
			--verbose; then
			log_error "UploadRhcos failed for ${rhel}"
			failed+=("${rhel}")
		fi
	done

	if [[ ${#failed[@]} -gt 0 ]]; then
		log_error "UploadRhcos failed for: ${failed[*]}"
		return 1
	fi
}

#######################################
# Entry point for the PowerVC podman step.
#
# Orchestrates the full sequence in order:
#   1. Verifies the mounted secrets directory exists; exits if it is absent.
#   2. Calls validate_environment to confirm required variables are set.
#   3. Calls install_required_tools to download helper binaries (PowerVC-Tool,
#      UploadRhcos, yq-v4) and create the pvcctl wrapper on PATH.
#   4. Calls setup_openstack_config to install the OpenStack credentials.
#   5. Calls setup_config_yaml to generate and populate pvcctl's config.yaml.
#   6. Uploads any missing RHCOS images.
#
# Globals:
#   SECRETS_DIR – (in) path to the mounted PowerVC credentials secret.
#   CLOUD       – (in) validated by validate_environment.
# Returns:
#   0 on success; non-zero (and logs an error) if any step fails.
#######################################
function main() {
	log_info "=== PowerVC Podman Script Started ==="

	# Ensure the mounted secrets directory exists.
	if [[ ! -d "${SECRETS_DIR}" ]]; then
		log_error "Secrets directory does not exist: ${SECRETS_DIR}"
		exit 1
	fi

	# Validate required inputs.
	validate_environment

	# Download helper binaries and create the pvcctl wrapper.
	install_required_tools

	# Setup the OpenStack configuration
	setup_openstack_config

	# Generate and populate pvcctl's config.yaml.
	setup_config_yaml

	# Upload any missing RHCOS images
	upload_rhcos_images

	log_info "=== PowerVC Podman Script Completed ==="
}

main
