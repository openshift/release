#!/bin/bash

# Exit on errors, unset variables, and failed pipelines.
set -o nounset
set -o errexit
set -o pipefail

# Tool versions.
readonly POWERVC_TOOL_VERSION="v2.4.10"
readonly YQ_VERSION="v4.53.6"

# Path to the mounted secret volume containing all PowerVC credentials.
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

# On any non-zero exit, log a warning; cleanup_on_exit suppresses the message
# for a clean (rc=0) exit so it only fires on genuine failures.
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
#   CLOUD        – name of the cloud in clouds.yaml; supplied by the step's env
#                  default and validated here for parity with the other PowerVC steps.
#   UPLOAD_IMAGES – controls whether upload_rhcos_images is called by main().
#
# Globals:
#   CLOUD         – (in) must be non-empty; validated but not modified.
#   UPLOAD_IMAGES – (in) must be non-empty; validated but not modified.
# Returns:
#   0 if all required variables are set; exits non-zero listing every missing
#   variable if any are absent.
#######################################
function validate_environment() {
	log_info "Validating environment variables..."

	local required_vars=(
		"CLOUD"
		"UPLOAD_IMAGES"
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
# target file and its matching .sha256 file, verifies the checksum, and then
# removes the .sha256 file; the executable is left in place only when
# verification succeeds.  When disabled the SHA download and check are skipped
# entirely.
#
# Arguments:
#   $1 - Source URL.
#   $2 - Destination path for the downloaded file.
#   $3 - Human-readable description used in log messages.
#   $4 - (optional) Whether to download and verify the SHA256 checksum.
#        Must be exactly "true" or "false". Defaults to "true". Any other
#        value is treated as an error rather than silently skipping verification.
# Returns:
#   0 if the file is downloaded (and checksum verification passes when enabled).
#   1 if a download fails or checksum verification fails.
# Side Effects:
#   Writes the binary at the destination path and marks it executable.
#   The .sha256 file is a transient intermediary and is removed after
#   verification (success or failure).
#######################################
function download_tool_w_sha() {
	local url="${1}"
	local output="${2}"
	local description="${3}"
	local verify_sha="${4:-true}"
	local rc=0

	if [[ "${verify_sha}" != "true" && "${verify_sha}" != "false" ]]; then
		log_error "download_tool_w_sha: verify_sha must be 'true' or 'false', got '${verify_sha}'"
		return 1
	fi

	log_info "Downloading ${description} from ${url}"
	if ! retry_command 3 5 "Download ${description}" \
		curl --fail --location --silent \
			--show-error --connect-timeout 30 --max-time 120 \
			--output "${output}" "${url}"; then
		log_error "Could not download ${url}"
		return 1
	fi

	if [[ "${verify_sha}" == "true" ]]; then
		local sha_url="${url}.sha256"
		local sha_output="${output}.sha256"
		log_info "Downloading ${description} SHA256 from ${sha_url}"
		if ! retry_command 3 5 "Download ${description} SHA256" \
			curl --fail --location --silent \
				--show-error --connect-timeout 30 --max-time 120 \
				--output "${sha_output}" "${sha_url}"; then
			log_error "Could not download ${sha_url}"
			return 1
		fi

		pushd "$(dirname "${sha_output}")" > /dev/null || {
			log_error "Failed to change directory to $(dirname "${sha_output}")"
			return 1
		}
		if ! sha256sum --check "$(basename "${sha_output}")"; then
			log_error "sha256 sum failed verification"
			rm -f "${sha_output}" "${output}"
			popd > /dev/null || true
			return 1
		fi
		rm -f "${sha_output}"
		popd > /dev/null || rc=$?
	fi

	chmod +x "${output}"

	log_info "Successfully installed ${description}"

	return ${rc}
}

#######################################
# Download a mikefarah/yq release asset, verify its SHA256 checksum, and install
# it at the requested path.
#
# Defined as a subshell function (parenthesised body) so its cd/trap/local
# changes are isolated and the temporary download directory is always removed by
# the EXIT trap when the subshell returns.
#
# Arguments:
#   $1 - yq release version tag (required, e.g. v4.53.6).
#   $2 - (optional) release asset name. Defaults to yq_linux_amd64.
#   $3 - (optional) destination path for the installed binary. Defaults to yq.
# Returns:
#   0 on success; 1 if a download fails, the checksum file is malformed, or
#   verification fails.
# Side Effects:
#   Creates the parent directory of the destination path if it does not exist.
#   Writes the verified binary (mode 0755) to the destination path.
#######################################
download_yq() (
	local version="${1:?Usage: download_yq <version> [asset] [output]}"
	local asset="${2:-yq_linux_amd64}"
	local output="${3:-yq}"
	local base_url="https://github.com/mikefarah/yq/releases/download/${version}"
	local tmpdir expected actual sha256_col

	tmpdir="$(mktemp -d)"
	# This EXIT trap requires the parenthesised (subshell) function body above:
	# in a subshell it is trap-local and fires on return, cleaning tmpdir. With a
	# brace body it would instead REPLACE the script-level EXIT trap (line 59),
	# and since tmpdir is local, the script would fail at exit with
	# "tmpdir: unbound variable" under `set -o nounset`. Do not switch to `{ }`.
	trap 'rm -rf -- "$tmpdir"' EXIT

	# All downloads are wrapped in explicit retry_command checks; curl itself
	# does not use --retry.
	if ! retry_command 3 5 "Download ${asset}" \
		curl --fail --silent --show-error --location \
			--connect-timeout 30 --max-time 120 \
			--output "$tmpdir/$asset" "$base_url/$asset"; then
		log_error "Could not download ${base_url}/${asset}"
		return 1
	fi

	if ! retry_command 3 5 "Download checksums" \
		curl --fail --silent --show-error --location \
			--connect-timeout 30 --max-time 120 \
			--output "$tmpdir/checksums" "$base_url/checksums"; then
		log_error "Could not download ${base_url}/checksums"
		return 1
	fi

	if ! retry_command 3 5 "Download checksums_hashes_order" \
		curl --fail --silent --show-error --location \
			--connect-timeout 30 --max-time 120 \
			--output "$tmpdir/checksums_hashes_order" "$base_url/checksums_hashes_order"; then
		log_error "Could not download ${base_url}/checksums_hashes_order"
		return 1
	fi

	# Determine which 1-based line number SHA-256 occupies in the hash order
	# file, then add 1 because the checksums file prepends the filename as $1.
	sha256_col="$(grep -n '^SHA-256$' "$tmpdir/checksums_hashes_order" | cut -d: -f1)"
	if [[ -z "${sha256_col}" ]]; then
		log_error "Could not locate SHA-256 in checksums_hashes_order"
		return 1
	fi
	(( sha256_col += 1 ))

	expected="$(awk -v asset="${asset}" -v col="${sha256_col}" \
		'$1 == asset { print $col }' "$tmpdir/checksums" \
		| tr '[:upper:]' '[:lower:]')"

	if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
		log_error "Could not extract SHA-256 checksum for ${asset} from checksums file"
		return 1
	fi

	actual="$(sha256sum -- "$tmpdir/$asset" | awk '{ print $1 }')"

	if [[ "$actual" != "$expected" ]]; then
		log_error "Checksum verification FAILED for ${asset}"
		log_error "Expected: ${expected} Actual: ${actual}"
		return 1
	fi

	if ! mkdir -p -- "$(dirname -- "${output}")" \
		|| ! chmod 0755 "$tmpdir/$asset" \
		|| ! mv -- "$tmpdir/$asset" "$output"; then
		log_error "Failed to install ${asset} to ${output}"
		return 1
	fi

	log_info "Checksum OK: ${output}"
)

#######################################
# Download helper binaries and expose them on PATH so subsequent steps can
# drive the PowerVC cloud.
#
# The function performs the following steps in order:
#   1. Changes to /tmp and creates a private, mode-0700 HOME directory under
#      /var/tmp/powervc-checks.XXXXXX so anything written there is not world-
#      readable.
#   2. Creates /tmp/bin and prepends it to PATH.
#   3. Detects the host architecture (x86_64 → amd64, ppc64le/amd64 used as-is,
#      anything else is an error) and downloads the matching ocp-ipi-powervc
#      and UploadRhcosAPI binaries from the IBM GitHub release at
#      POWERVC_TOOL_VERSION (with SHA256 verification), then renames them to
#      the stable names PowerVC-Tool and UploadRhcosAPI. Downloads are retried up
#      to 3 times with a constant 5-second delay before the function exits
#      non-zero.
#   4. Installs yq-v4 at YQ_VERSION from the mikefarah/yq GitHub release (with
#      SHA256 verification, via download_yq) unless a yq-v4 is already
#      resolvable on PATH.
#   5. Verifies that PowerVC-Tool, UploadRhcosAPI, and yq-v4 are
#      resolvable on PATH.
#
# Globals:
#   POWERVC_TOOL_VERSION – (in)  IBM GitHub release tag used to build the
#                                download URL.
#   YQ_VERSION           – (in)  mikefarah/yq release tag for yq-v4.
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

	# Make a private directory that is only readable by us.
	HOME="$(mktemp -d /var/tmp/powervc-checks.XXXXXX)"
	chmod 0700 "${HOME}"
	log_info "HOME is now ${HOME}"
	export HOME

	mkdir -p "${tmp_bin_dir}" || {
		log_error "Failed to create ${tmp_bin_dir} directory"
		exit 1
	}

	PATH="${tmp_bin_dir}:${PATH}"
	log_info "PATH is now ${PATH}"
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

	log_info "Downloading UploadRhcosAPI version ${POWERVC_TOOL_VERSION}"
	local uploadrhcos_bin="UploadRhcosAPI-linux-${machine}"
	powervc_url="https://github.com/IBM/ocp-ipi-powervc/releases/download/${POWERVC_TOOL_VERSION}/${uploadrhcos_bin}"
	if ! download_tool_w_sha "${powervc_url}" "${tmp_bin_dir}/${uploadrhcos_bin}" "${uploadrhcos_bin} ${POWERVC_TOOL_VERSION}"; then
		log_error "Could not download ${powervc_url}"
		exit 1
	fi
	mv "${tmp_bin_dir}/${uploadrhcos_bin}" "${tmp_bin_dir}/UploadRhcosAPI"

	# Install yq-v4 if not present.
	log_info "Checking for yq-v4..."
	local cmd_yq
	cmd_yq="$(command -v yq-v4 2>/dev/null || true)"

	if [[ ! -x "${cmd_yq}" ]]; then
		log_info "Downloading yq-v4 version ${YQ_VERSION}"
		local yq_arch
		yq_arch=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')

		if ! download_yq "${YQ_VERSION}" "yq_linux_${yq_arch}" "${tmp_bin_dir}/yq-v4"; then
			log_error "Could not download yq-v4 version ${YQ_VERSION}"
			exit 1
		fi
	else
		log_info "yq-v4 already installed at ${cmd_yq}"
	fi

	# Verify all required tools are available.
	log_info "Verifying installed tools..."
	local tools=("PowerVC-Tool" "UploadRhcosAPI" "yq-v4")
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

	# The secret's clouds.yaml hard-codes /tmp/ocp-ci-ca.pem as the CA path,
	# but the working directory is HOME (set by install_required_tools), not /tmp.
	# Rewrite both installed copies so the tools find the CA file at its real location.
	sed -i -e "s|/tmp/ocp-ci-ca.pem|${HOME}/ocp-ci-ca.pem|" "${HOME}/clouds.yaml"
	sed -i -e "s|/tmp/ocp-ci-ca.pem|${HOME}/ocp-ci-ca.pem|" "${HOME}/.config/openstack/clouds.yaml"
}

#######################################
# Upload any missing RHCOS images for the supported releases via UploadRhcosAPI.
#
# Builds the repeated --release arguments from the releases array so the list
# is defined in one place, then invokes UploadRhcosAPI once per RHEL version in
# the rhels array.
#
# Every RHEL version is attempted even if an earlier one fails; the failures
# are collected and reported together, and the function returns non-zero if any
# RHEL version failed.
#
# Globals:
#   CLOUD        – (in)  cloud name used to extract auth_url from clouds.yaml.
#   SECRETS_DIR  – (in)  used indirectly via read_secret for credential files;
#                        clouds.yaml is read from HOME (the patched copy).
#   HOME         – (in)  working directory; clouds.yaml must
#                        exist here (set by install_required_tools and
#                        setup_openstack_config).
#   SVC_HOST     – (out) exported from secret SVC_HOST.
#   SVC_USER     – (out) exported from secret SVC_USER.
#   SVC_PASSWORD – (out) exported from secret SVC_PASSWORD.
#   POWERVC_USER – (out) exported from secret POWERVC_USER_ID.
#   POWERVC_PASSWORD – (out) exported from secret POWERVC_PASSWORD.
#   POWERVC_URL  – (out) constructed from clouds.yaml auth_url + /v3; exported
#                        for child processes via strenv().
# Returns:
#   0 if UploadRhcosAPI succeeds for every RHEL version; 1 otherwise.
#######################################
function upload_rhcos_images() {
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
	local log_file="/tmp/upload.log"

	cd "${HOME}" || {
		log_error "Failed to change directory to ${HOME}"
		exit 1
	}

	# Build the repeated --release arguments (shared across all RHEL versions).
	for release in "${releases[@]}"; do
		release_args+=(--release "${release}")
	done

	# Read each secret into a standalone assignment. A combined
	# `local var=$(read_secret ...)` would mask a read_secret exit with the
	# always-zero exit code of the local builtin, preventing errexit from firing.
	# Declaring local separately keeps errexit able to see the failure.
	local svc_host
	local svc_user
	local svc_password
	local template
	svc_host="$(read_secret SVC_HOST)"
	svc_user="$(read_secret SVC_USER)"
	svc_password="$(read_secret SVC_PASSWORD)"
	template="$(read_secret TEMPLATE)"

	# Populate SVC credentials via strenv() so special characters are safe and
	# the secret values are never passed as command-line arguments.
	export SVC_HOST="${svc_host}"
	export SVC_USER="${svc_user}"
	export SVC_PASSWORD="${svc_password}"
	export TEMPLATE="${template}"

	local powervc_user
	local powervc_password
	powervc_user="$(read_secret POWERVC_USER_ID)"
	powervc_password="$(read_secret POWERVC_PASSWORD)"

	# Export PowerVC credentials via environment so special characters are safe
	# and the values are never passed as command-line arguments.
	export POWERVC_USER="${powervc_user}"
	export POWERVC_PASSWORD="${powervc_password}"

	# Pull the PowerVC auth URL from the installed clouds.yaml (already patched
	# to use the correct CA path by setup_openstack_config).
	# local is declared on its own line so that a yq-v4 failure is visible to
	# errexit; a combined `local POWERVC_URL=$(...)` would mask the exit code.
	# export is needed so child processes (yq-v4 strenv()) can read the value.
	local POWERVC_URL
	POWERVC_URL=$(CLOUD="${CLOUD}" yq-v4 eval '.clouds[strenv(CLOUD)].auth.auth_url' "${HOME}/clouds.yaml")
	if [[ -z "${POWERVC_URL}" || "${POWERVC_URL}" == "null" ]]; then
		log_error "POWERVC_URL is empty or null (${POWERVC_URL})?"
		exit 1
	fi
	# Append /v3 because the Keystone auth/tokens endpoint requires the version
	# path; without it the API calls will fail with a 404.
	POWERVC_URL="${POWERVC_URL}/v3"

	export POWERVC_URL

	: > "${log_file}" # Ensure a clean log file for this run (truncate if it already exists).
	for rhel in "${rhels[@]}"; do
		log_info "Uploading RHCOS images for ${rhel}..."
		# Run inside an if-context so that errexit does not abort the loop on
		# failure — every RHEL version must be attempted regardless.
		if UploadRhcosAPI \
			"${release_args[@]}" \
			--rhel "${rhel}" \
			--verbose \
			2>&1 | tee -a "${log_file}"; then
			: # no-op: the then-branch must be non-empty; pipeline succeeded.
		else
			log_error "UploadRhcosAPI failed for ${rhel}"
			failed+=("${rhel}")
		fi
	done

	if [[ ${#failed[@]} -gt 0 ]]; then
		log_error "UploadRhcosAPI failed for: ${failed[*]}"
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
#      UploadRhcosAPI, yq-v4).
#   4. Calls setup_openstack_config to install the OpenStack credentials.
#   5. Uploads any missing RHCOS images.
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

	# Download helper binaries.
	install_required_tools

	# Install the OpenStack credentials.
	setup_openstack_config

	# Upload any missing RHCOS images.
	if [[ "${UPLOAD_IMAGES}" == "true" ]]; then
		upload_rhcos_images
	else
		log_info "skipping upload_rhcos_images as UPLOAD_IMAGES is false"
	fi

	log_info "=== PowerVC Podman Script Completed ==="
}

main
