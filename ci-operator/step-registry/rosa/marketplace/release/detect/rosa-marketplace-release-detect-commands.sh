#!/bin/bash

set -euo pipefail

readonly RELEASE_CONTROLLER_API="${RELEASE_CONTROLLER_API:-https://amd64.ocp.releases.ci.openshift.org}"
readonly RELEASE_CONTROLLER_RETRIES="${RELEASE_CONTROLLER_RETRIES:-3}"
readonly RELEASE_CONTROLLER_RETRY_DELAY_SECONDS="${RELEASE_CONTROLLER_RETRY_DELAY_SECONDS:-2}"
readonly RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS="${RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS:-30}"
readonly RELEASE_CONTROLLER_MAX_RESPONSE_BYTES="${RELEASE_CONTROLLER_MAX_RESPONSE_BYTES:-10485760}"
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

select_missing_rosa_y_stream() {
  local ready_file="$1"
  local rosa_versions_file="$2"

  "${PYTHON_BIN}" - "${ready_file}" "${rosa_versions_file}" <<'PYTHON'
import json
import re
import sys


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as source:
            return json.load(source)
    except (OSError, ValueError) as error:
        print("invalid JSON in {}: {}".format(path, error), file=sys.stderr)
        sys.exit(2)


ready = load_json(sys.argv[1])
rosa_versions = load_json(sys.argv[2])
nightly_pattern = re.compile(r"^(\d+)\.(\d+)\.0-0\.nightly$")
version_pattern = re.compile(r"^(\d+)\.(\d+)(?:\.|$)")

if not isinstance(ready, dict):
    sys.exit(2)

ocp_y_streams = set()
for stream, payloads in ready.items():
    match = nightly_pattern.fullmatch(stream)
    if not match:
        continue
    if payloads is None:
        payloads = []
    if not isinstance(payloads, list) or any(not isinstance(item, str) for item in payloads):
        sys.exit(2)
    if payloads:
        ocp_y_streams.add((int(match.group(1)), int(match.group(2))))

if not ocp_y_streams:
    sys.exit(4)

if not isinstance(rosa_versions, dict) or not isinstance(rosa_versions.get("items"), list):
    sys.exit(2)

rosa_y_streams = set()
for item in rosa_versions["items"]:
    if not isinstance(item, dict):
        sys.exit(2)
    raw_id = item.get("raw_id")
    if not isinstance(raw_id, str):
        continue
    match = version_pattern.match(raw_id)
    if match:
        rosa_y_streams.add((int(match.group(1)), int(match.group(2))))

latest_ocp = max(ocp_y_streams)
if latest_ocp in rosa_y_streams:
    sys.exit(3)

print("{}.{}".format(*latest_ocp))
PYTHON
}

main() {
  local ready_file
  local rosa_versions_file
  local ocp_version=""
  local selection_rc=0

  validate_settings
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rosa-marketplace-release-detect.XXXXXX") \
    || fail "failed to create temporary work directory"
  trap cleanup EXIT
  ready_file="${WORK_DIR}/ready-nightlies.json"
  rosa_versions_file="${WORK_DIR}/rosa-versions.json"

  http_get "${RELEASE_CONTROLLER_API}/api/v1/releasestreams/ready" \
    "${ready_file}" "ready-nightlies"

  login_ocm
  "${OCM_BIN}" get "/api/clusters_mgmt/v1/versions" \
    --parameter "search=rosa_enabled = 'true'" \
    --parameter "size=1000" > "${rosa_versions_file}" \
    || fail "failed to query ROSA-enabled OCM versions"

  if ocp_version=$(select_missing_rosa_y_stream "${ready_file}" "${rosa_versions_file}"); then
    write_value "${ocp_version}" "${OCP_VERSION_FILE}"
    write_value "ready" "${STATE_FILE}"
    log "Detected OCP nightly y-stream without a ROSA-enabled OCM version: ${ocp_version}"
    return 0
  else
    selection_rc=$?
  fi

  case "${selection_rc}" in
    3)
      set_wait_state "rosa-release-current"
      ;;
    4)
      set_wait_state "ready-nightly-unavailable"
      ;;
    *)
      fail "release or OCM version response has an invalid schema"
      ;;
  esac
}

main "$@"
