#!/bin/bash

set -euo pipefail

readonly RELEASE_CONTROLLER_API="${RELEASE_CONTROLLER_API:-https://amd64.ocp.releases.ci.openshift.org}"
readonly RELEASE_CONTROLLER_RETRIES="${RELEASE_CONTROLLER_RETRIES:-3}"
readonly RELEASE_CONTROLLER_RETRY_DELAY_SECONDS="${RELEASE_CONTROLLER_RETRY_DELAY_SECONDS:-2}"
readonly RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS="${RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS:-30}"
readonly RELEASE_CONTROLLER_MAX_RESPONSE_BYTES="${RELEASE_CONTROLLER_MAX_RESPONSE_BYTES:-10485760}"
readonly OCM_RESULT_SIZE=1
readonly OCM_REQUEST_TIMEOUT_SECONDS="${OCM_REQUEST_TIMEOUT_SECONDS:-30}"
readonly OCM_RETRIES="${OCM_RETRIES:-3}"
readonly OCM_RETRY_DELAY_SECONDS="${OCM_RETRY_DELAY_SECONDS:-2}"
readonly OCM_LOGIN_ENV="${OCM_LOGIN_ENV:-production}"
readonly ROSA_CREDENTIALS_DIR="${ROSA_CREDENTIALS_DIR:-/etc/rosa-credentials}"
readonly CURL_BIN="${CURL_BIN:-curl}"
readonly OCM_BIN="${OCM_BIN:-ocm}"
readonly PYTHON_BIN="${PYTHON_BIN:-python3}"
readonly SLEEP_BIN="${SLEEP_BIN:-sleep}"
readonly SHARED_DIR="${SHARED_DIR:-/tmp}"

readonly STATE_FILE="${SHARED_DIR}/rosa-marketplace-release-state"
readonly OCP_VERSION_FILE="${SHARED_DIR}/rosa-marketplace-ocp-version"

WORK_DIR=""

cleanup() {
  if [[ -n "${WORK_DIR}" ]]; then
    rm -rf -- "${WORK_DIR}"
  fi
}

log() {
  printf '[rosa-marketplace-release-detect] %s\n' "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

write_value() {
  local value="$1"
  local destination="$2"

  printf '%s\n' "${value}" > "${destination}"
}

set_wait_state() {
  local reason="$1"

  write_value "wait:${reason}" "${STATE_FILE}"
  log "No action: ${reason}"
}

validate_settings() {
  [[ "${RELEASE_CONTROLLER_API}" == https://* ]] || fail "RELEASE_CONTROLLER_API must use https://"
  [[ "${RELEASE_CONTROLLER_API}" != *'@'* ]] || fail "RELEASE_CONTROLLER_API must not contain userinfo"
  [[ "${RELEASE_CONTROLLER_API}" != *'?'* && "${RELEASE_CONTROLLER_API}" != *'#'* ]] \
    || fail "RELEASE_CONTROLLER_API must not contain a query or fragment"
  [[ "${RELEASE_CONTROLLER_RETRIES}" =~ ^[1-9][0-9]*$ ]] || fail "RELEASE_CONTROLLER_RETRIES must be a positive integer"
  [[ "${RELEASE_CONTROLLER_RETRY_DELAY_SECONDS}" =~ ^[0-9]+$ ]] || fail "RELEASE_CONTROLLER_RETRY_DELAY_SECONDS must be a non-negative integer"
  [[ "${RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS}" =~ ^[1-9][0-9]*$ ]] || fail "RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS must be a positive integer"
  [[ "${RELEASE_CONTROLLER_MAX_RESPONSE_BYTES}" =~ ^[1-9][0-9]*$ ]] || fail "RELEASE_CONTROLLER_MAX_RESPONSE_BYTES must be a positive integer"
  [[ "${OCM_REQUEST_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] || fail "OCM_REQUEST_TIMEOUT_SECONDS must be a positive integer"
  [[ "${OCM_RETRIES}" =~ ^[1-9][0-9]*$ ]] || fail "OCM_RETRIES must be a positive integer"
  [[ "${OCM_RETRY_DELAY_SECONDS}" =~ ^[0-9]+$ ]] || fail "OCM_RETRY_DELAY_SECONDS must be a non-negative integer"
  (( RELEASE_CONTROLLER_RETRY_DELAY_SECONDS <= RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS )) \
    || fail "RELEASE_CONTROLLER_RETRY_DELAY_SECONDS must not exceed RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS"
  case "${OCM_LOGIN_ENV}" in
    production|staging|integration)
      ;;
    *)
      fail "OCM_LOGIN_ENV must be production, staging, or integration"
      ;;
  esac

  mkdir -p "${SHARED_DIR}"
  require_command "${CURL_BIN}"
  require_command mktemp
  require_command "${OCM_BIN}"
  require_command "${PYTHON_BIN}"
  require_command rm
  require_command "${SLEEP_BIN}"
}

login_ocm() {
  local client_id=""
  local client_secret=""
  local offline_token=""

  [[ -f "${ROSA_CREDENTIALS_DIR}/sso-client-id" ]] \
    && client_id=$(<"${ROSA_CREDENTIALS_DIR}/sso-client-id")
  [[ -f "${ROSA_CREDENTIALS_DIR}/sso-client-secret" ]] \
    && client_secret=$(<"${ROSA_CREDENTIALS_DIR}/sso-client-secret")
  [[ -f "${ROSA_CREDENTIALS_DIR}/ocm-token" ]] \
    && offline_token=$(<"${ROSA_CREDENTIALS_DIR}/ocm-token")

  if [[ -n "${client_id}" && -n "${client_secret}" ]]; then
    log "Logging into OCM ${OCM_LOGIN_ENV} with SSO credentials"
    "${OCM_BIN}" login --url "${OCM_LOGIN_ENV}" \
      --client-id "${client_id}" --client-secret "${client_secret}"
  elif [[ -n "${offline_token}" ]]; then
    log "Logging into OCM ${OCM_LOGIN_ENV} with an offline token"
    "${OCM_BIN}" login --url "${OCM_LOGIN_ENV}" --token "${offline_token}"
  else
    fail "no OCM credentials found in ${ROSA_CREDENTIALS_DIR}"
  fi
}

http_get() {
  local url="$1"
  local destination="$2"
  local request_name="$3"
  local attempt=1
  local curl_rc=0
  local http_code=""
  local response_size=0
  local retry_delay="${RELEASE_CONTROLLER_RETRY_DELAY_SECONDS}"

  while (( attempt <= RELEASE_CONTROLLER_RETRIES )); do
    if http_code=$("${CURL_BIN}" \
      --silent \
      --show-error \
      --proto '=https' \
      --proto-redir '=https' \
      --location \
      --connect-timeout 10 \
      --max-time 30 \
      --max-filesize "${RELEASE_CONTROLLER_MAX_RESPONSE_BYTES}" \
      --output "${destination}" \
      --write-out '%{http_code}' \
      "${url}"); then
      curl_rc=0
    else
      curl_rc=$?
    fi

    if (( curl_rc == 0 )) && [[ -f "${destination}" ]]; then
      response_size=$(wc -c < "${destination}")
      if (( response_size > RELEASE_CONTROLLER_MAX_RESPONSE_BYTES )); then
        curl_rc=63
        http_code=""
        : > "${destination}"
      fi
    fi

    if (( curl_rc == 0 )) && [[ "${http_code}" == "200" ]]; then
      return 0
    fi

    if (( attempt == RELEASE_CONTROLLER_RETRIES )); then
      fail "${request_name} request failed after ${RELEASE_CONTROLLER_RETRIES} attempts (curl_rc=${curl_rc}, http_code=${http_code:-none})"
    fi

    log "${request_name} request failed (attempt ${attempt}/${RELEASE_CONTROLLER_RETRIES}); retrying"
    if (( retry_delay > 0 )); then
      "${SLEEP_BIN}" "${retry_delay}"
      retry_delay=$((retry_delay * 2))
      if (( retry_delay > RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS )); then
        retry_delay="${RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS}"
      fi
    fi
    attempt=$((attempt + 1))
  done
}

# List every X.Y with an accepted nightly payload, newest first.
discover_accepted_nightly_streams() {
  local accepted_file="$1"

  "${PYTHON_BIN}" - "${accepted_file}" <<'PYTHON'
import json
import re
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as source:
        accepted = json.load(source)
except (OSError, ValueError):
    sys.exit(2)

if not isinstance(accepted, dict):
    sys.exit(2)

nightly_pattern = re.compile(r"^(\d+)\.(\d+)\.0-0\.nightly$")
versions = set()
for stream, payloads in accepted.items():
    match = nightly_pattern.fullmatch(stream)
    if not match:
        continue
    if not isinstance(payloads, list) or any(not isinstance(item, str) for item in payloads):
        sys.exit(2)
    if payloads:
        versions.add((int(match.group(1)), int(match.group(2))))

for major, minor in sorted(versions, reverse=True):
    print("{}.{}".format(major, minor))
PYTHON
}

# Confirm that OCM's filtered response belongs to the requested X.Y.
ocm_version_exists() {
  local response_file="$1"
  local ocp_version="$2"

  "${PYTHON_BIN}" - "${response_file}" "${ocp_version}" <<'PYTHON'
import json
import sys

def invalid(reason):
    print("invalid OCM version response: {}".format(reason), file=sys.stderr)
    sys.exit(2)

try:
    with open(sys.argv[1], "r", encoding="utf-8") as source:
        response = json.load(source)
except (OSError, ValueError):
    invalid("unreadable JSON")

if not isinstance(response, dict) or not isinstance(response.get("items"), list):
    invalid("missing items list")
if type(response.get("total")) is not int or response["total"] < 0:
    invalid("invalid total")
items = response["items"]
if response["total"] == 0:
    if items:
        invalid("items present with zero total")
    sys.exit(1)
if not items or len(items) > response["total"]:
    invalid("total and items disagree")
for item in items:
    if not isinstance(item, dict):
        invalid("invalid item")
    raw_id = item.get("raw_id")
    if not isinstance(raw_id, str) or not raw_id.startswith(sys.argv[2] + "."):
        invalid("item does not match requested X.Y")
PYTHON
}

ocm_get_version() {
  local ocp_version="$1"
  local destination="$2"
  local attempt=1
  local retry_delay="${OCM_RETRY_DELAY_SECONDS}"
  local response_size

  while (( attempt <= OCM_RETRIES )); do
    if "${PYTHON_BIN}" - "${OCM_BIN}" "${ocp_version}" "${OCM_RESULT_SIZE}" "${OCM_REQUEST_TIMEOUT_SECONDS}" \
      > "${destination}" <<'PYTHON'
import subprocess
import sys

command = [
    sys.argv[1], "get", "/api/clusters_mgmt/v1/versions",
    "--parameter", "search=rosa_enabled = 'true' AND raw_id like '{}.%'".format(sys.argv[2]),
    "--parameter", "page=1",
    "--parameter", "size={}".format(sys.argv[3]),
]
try:
    result = subprocess.run(
        command, stdout=sys.stdout.buffer, stderr=subprocess.DEVNULL,
        timeout=int(sys.argv[4]), check=False,
    )
except subprocess.TimeoutExpired:
    sys.exit(124)
sys.exit(result.returncode)
PYTHON
    then
      response_size=$(wc -c < "${destination}")
      (( response_size <= RELEASE_CONTROLLER_MAX_RESPONSE_BYTES )) \
        || fail "OCM version response for ${ocp_version} exceeds response limit"
      return 0
    fi
    if (( attempt == OCM_RETRIES )); then
      fail "failed to query ROSA-enabled OCM version ${ocp_version} after ${OCM_RETRIES} attempts"
    fi
    log "OCM version ${ocp_version} request failed (attempt ${attempt}/${OCM_RETRIES}); retrying"
    if (( retry_delay > 0 )); then
      "${SLEEP_BIN}" "${retry_delay}"
      retry_delay=$((retry_delay * 2))
    fi
    attempt=$((attempt + 1))
  done
}

main() {
  local accepted_file
  local accepted_versions
  local ocp_version=""
  local newest_missing=""
  local lookup_rc=0
  local -a missing=()

  validate_settings
  rm -f -- "${STATE_FILE}" "${OCP_VERSION_FILE}"
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rosa-marketplace-release-detect.XXXXXX") \
    || fail "failed to create temporary work directory"
  trap cleanup EXIT
  accepted_file="${WORK_DIR}/accepted-nightlies.json"
  mkdir -p "${WORK_DIR}/rosa"

  http_get "${RELEASE_CONTROLLER_API}/api/v1/releasestreams/accepted" \
    "${accepted_file}" "accepted-nightlies"
  accepted_versions=$(discover_accepted_nightly_streams "${accepted_file}") \
    || fail "invalid accepted OCP nightly response"
  if [[ -z "${accepted_versions}" ]]; then
    set_wait_state "ocp-release-unavailable"
    return 0
  fi

  login_ocm
  while IFS= read -r ocp_version; do
    ocm_get_version "${ocp_version}" "${WORK_DIR}/rosa/${ocp_version}.json"
    if ocm_version_exists "${WORK_DIR}/rosa/${ocp_version}.json" "${ocp_version}"; then
      continue
    else
      lookup_rc=$?
    fi
    (( lookup_rc == 1 )) || fail "invalid OCM version response for ${ocp_version}"
    missing+=("${ocp_version}")
    if [[ -z "${newest_missing}" ]]; then
      newest_missing="${ocp_version}"
    fi
  done <<< "${accepted_versions}"

  if [[ -n "${newest_missing}" ]]; then
    log "Accepted OCP nightly X.Y without a ROSA-enabled OCM version: ${missing[*]}"
    write_value "${newest_missing}" "${OCP_VERSION_FILE}"
    write_value "ready" "${STATE_FILE}"
    log "Detected newest missing OCP X.Y: ${newest_missing}"
    return 0
  fi
  set_wait_state "rosa-release-current"
}

main "$@"
