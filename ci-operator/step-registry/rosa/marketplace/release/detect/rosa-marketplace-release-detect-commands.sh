#!/bin/bash

set -euo pipefail

readonly RELEASE_CONTROLLER_API="${RELEASE_CONTROLLER_API:-https://amd64.ocp.releases.ci.openshift.org}"
readonly RELEASE_CONTROLLER_RETRIES="${RELEASE_CONTROLLER_RETRIES:-3}"
readonly RELEASE_CONTROLLER_RETRY_DELAY_SECONDS="${RELEASE_CONTROLLER_RETRY_DELAY_SECONDS:-2}"
readonly RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS="${RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS:-30}"
readonly RELEASE_CONTROLLER_MAX_RESPONSE_BYTES="${RELEASE_CONTROLLER_MAX_RESPONSE_BYTES:-10485760}"
readonly RELEASE_PAYLOAD_AUTH_FILE="${RELEASE_PAYLOAD_AUTH_FILE:-/etc/pull-secret/.dockerconfigjson}"
readonly RHCOS_AWS_REGION="${RHCOS_AWS_REGION:-us-east-1}"
readonly CURL_BIN="${CURL_BIN:-curl}"
readonly PYTHON_BIN="${PYTHON_BIN:-python3}"
readonly OC_BIN="${OC_BIN:-oc}"
readonly SLEEP_BIN="${SLEEP_BIN:-sleep}"
readonly SHARED_DIR="${SHARED_DIR:-/tmp}"
readonly ARTIFACT_DIR="${ARTIFACT_DIR:-${SHARED_DIR}}"

readonly STATE_FILE="${SHARED_DIR}/rosa-marketplace-release-state"
readonly OCP_VERSION_FILE="${SHARED_DIR}/rosa-marketplace-ocp-version"
readonly PAYLOAD_TAG_FILE="${SHARED_DIR}/rosa-marketplace-payload-tag"
readonly PAYLOAD_PULLSPEC_FILE="${SHARED_DIR}/rosa-marketplace-payload-pullspec"
readonly RHCOS_VERSION_FILE="${SHARED_DIR}/rosa-marketplace-rhcos-version"
readonly RHCOS_AMI_FILE="${SHARED_DIR}/rosa-marketplace-rhcos-ami"

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
  [[ -n "${TARGET_OCP_Y_STREAM:-}" ]] || fail "TARGET_OCP_Y_STREAM is required"
  [[ "${TARGET_OCP_Y_STREAM}" =~ ^[0-9]+\.[0-9]+$ ]] || fail "TARGET_OCP_Y_STREAM must have major.minor form"
  [[ "${RELEASE_CONTROLLER_RETRIES}" =~ ^[1-9][0-9]*$ ]] || fail "RELEASE_CONTROLLER_RETRIES must be a positive integer"
  [[ "${RELEASE_CONTROLLER_RETRY_DELAY_SECONDS}" =~ ^[0-9]+$ ]] || fail "RELEASE_CONTROLLER_RETRY_DELAY_SECONDS must be a non-negative integer"
  [[ "${RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS}" =~ ^[1-9][0-9]*$ ]] || fail "RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS must be a positive integer"
  [[ "${RELEASE_CONTROLLER_MAX_RESPONSE_BYTES}" =~ ^[1-9][0-9]*$ ]] || fail "RELEASE_CONTROLLER_MAX_RESPONSE_BYTES must be a positive integer"
  (( RELEASE_CONTROLLER_RETRY_DELAY_SECONDS <= RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS )) \
    || fail "RELEASE_CONTROLLER_RETRY_DELAY_SECONDS must not exceed RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS"

  mkdir -p "${SHARED_DIR}" "${ARTIFACT_DIR}"
  require_command "${CURL_BIN}"
  require_command "${PYTHON_BIN}"
  require_command "${SLEEP_BIN}"
}

json_tool() {
  "${PYTHON_BIN}" - "$@" <<'PYTHON'
import json
import sys


def load_json(path):
    try:
        with open(path, "r", encoding="utf-8") as source:
            return json.load(source)
    except (OSError, ValueError) as error:
        print("invalid JSON in {}: {}".format(path, error), file=sys.stderr)
        sys.exit(2)


def nested_string(data, keys):
    value = data
    for key in keys:
        if not isinstance(value, dict) or key not in value:
            sys.exit(2)
        value = value[key]
    if not isinstance(value, str) or not value:
        sys.exit(2)
    print(value)


action = sys.argv[1]
input_path = sys.argv[2]
data = load_json(input_path)

if action == "validate-config":
    expected_stream = sys.argv[3]
    if not isinstance(data, dict) or data.get("name") != expected_stream:
        sys.exit(2)
elif action == "select-payload":
    expected_stream = sys.argv[3]
    output_path = sys.argv[4]
    if not isinstance(data, dict) or data.get("name") != expected_stream:
        sys.exit(2)
    tags = data.get("tags", [])
    if tags is None:
        tags = []
    if not isinstance(tags, list):
        sys.exit(2)
    eligible = []
    for tag in tags:
        if not isinstance(tag, dict):
            sys.exit(2)
        if tag.get("phase") in ("Ready", "Accepted", "Rejected"):
            if not isinstance(tag.get("name"), str) or not tag["name"]:
                sys.exit(2)
            eligible.append(tag)
    if not eligible:
        sys.exit(3)
    selected = sorted(eligible, key=lambda tag: tag["name"])[0]
    try:
        with open(output_path, "w", encoding="utf-8") as destination:
            json.dump(selected, destination, sort_keys=True)
            destination.write("\n")
    except OSError as error:
        print("cannot write {}: {}".format(output_path, error), file=sys.stderr)
        sys.exit(2)
elif action == "payload-field":
    field = sys.argv[3]
    if not isinstance(data, dict):
        sys.exit(2)
    value = data.get(field)
    if not isinstance(value, str) or not value:
        sys.exit(2)
    if field == "phase" and value not in ("Ready", "Accepted", "Rejected"):
        sys.exit(2)
    print(value)
elif action == "rhcos-version":
    nested_string(data, ("architectures", "x86_64", "artifacts", "metal", "release"))
elif action == "rhcos-ami":
    region = sys.argv[3]
    nested_string(data, ("architectures", "x86_64", "images", "aws", "regions", region, "image"))
else:
    print("unknown JSON action: {}".format(action), file=sys.stderr)
    sys.exit(2)
PYTHON
}

http_get() {
  local url="$1"
  local destination="$2"
  local attempt=1
  local curl_rc=0
  local http_code=""
  local retry_delay="${RELEASE_CONTROLLER_RETRY_DELAY_SECONDS}"

  while (( attempt <= RELEASE_CONTROLLER_RETRIES )); do
    if http_code=$("${CURL_BIN}" \
      --silent \
      --show-error \
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

    if (( curl_rc == 0 )) && [[ "${http_code}" =~ ^[0-9]{3}$ ]]; then
      case "${http_code}" in
        429|5??)
          ;;
        *)
          HTTP_CODE="${http_code}"
          return 0
          ;;
      esac
    fi

    if (( attempt == RELEASE_CONTROLLER_RETRIES )); then
      fail "GET ${url} failed after ${RELEASE_CONTROLLER_RETRIES} attempts (curl_rc=${curl_rc}, http_code=${http_code:-none})"
    fi

    log "GET ${url} failed (attempt ${attempt}/${RELEASE_CONTROLLER_RETRIES}); retrying"
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

validate_stream_config() {
  local stream="$1"
  local config_file="$2"

  json_tool validate-config "${config_file}" "${stream}" \
    || fail "release-controller returned an invalid or mismatched stream config"
}

select_payload() {
  local stream="$1"
  local tags_file="$2"
  local selected_file="$3"
  local json_rc=0

  if json_tool select-payload "${tags_file}" "${stream}" "${selected_file}"; then
    return 0
  else
    json_rc=$?
  fi

  if (( json_rc == 3 )); then
    return 1
  fi
  fail "release-controller returned an invalid or mismatched tags response"
}

extract_rhcos_metadata() {
  local pullspec="$1"
  local coreos_stream_file="$2"
  local installer_dir
  local installer_bin

  if [[ -n "${ROSA_MARKETPLACE_INSTALLER_BIN:-}" ]]; then
    installer_bin="${ROSA_MARKETPLACE_INSTALLER_BIN}"
  else
    require_command "${OC_BIN}"
    [[ -s "${RELEASE_PAYLOAD_AUTH_FILE}" ]] || fail "release payload auth file is missing or empty: ${RELEASE_PAYLOAD_AUTH_FILE}"

    installer_dir=$(mktemp -d "${SHARED_DIR}/rosa-marketplace-installer.XXXXXX")
    "${OC_BIN}" adm release extract \
      -a "${RELEASE_PAYLOAD_AUTH_FILE}" \
      --command=openshift-install \
      --to="${installer_dir}" \
      "${pullspec}"
    installer_bin="${installer_dir}/openshift-install"
  fi

  [[ -x "${installer_bin}" ]] || fail "openshift-install is not executable: ${installer_bin}"
  "${installer_bin}" coreos print-stream-json > "${coreos_stream_file}"
}

main() {
  local stream
  local config_file="${ARTIFACT_DIR}/rosa-marketplace-release-config.json"
  local tags_file="${ARTIFACT_DIR}/rosa-marketplace-release-tags.json"
  local selected_file="${ARTIFACT_DIR}/rosa-marketplace-selected-payload.json"
  local coreos_stream_file="${ARTIFACT_DIR}/rosa-marketplace-coreos-stream.json"
  local payload_tag
  local payload_pullspec
  local payload_phase
  local rhcos_version
  local rhcos_ami

  validate_settings
  stream="${TARGET_OCP_Y_STREAM}.0-0.nightly"
  write_value "${TARGET_OCP_Y_STREAM}" "${OCP_VERSION_FILE}"
  log "Checking release stream ${stream}"

  http_get "${RELEASE_CONTROLLER_API}/api/v1/releasestream/${stream}/config" "${config_file}"
  case "${HTTP_CODE}" in
    200)
      validate_stream_config "${stream}" "${config_file}"
      ;;
    400|404)
      set_wait_state "stream-config-unavailable"
      return 0
      ;;
    *)
      fail "stream config returned unexpected HTTP ${HTTP_CODE}"
      ;;
  esac

  http_get "${RELEASE_CONTROLLER_API}/api/v1/releasestream/${stream}/tags" "${tags_file}"
  case "${HTTP_CODE}" in
    200)
      ;;
    404)
      set_wait_state "stream-tags-unavailable"
      return 0
      ;;
    *)
      fail "stream tags returned unexpected HTTP ${HTTP_CODE}"
      ;;
  esac

  if ! select_payload "${stream}" "${tags_file}" "${selected_file}"; then
    set_wait_state "built-nightly-unavailable"
    return 0
  fi

  payload_tag=$(json_tool payload-field "${selected_file}" name) \
    || fail "selected payload has no name"
  payload_pullspec=$(json_tool payload-field "${selected_file}" pullSpec) \
    || fail "selected payload has no pullSpec"
  payload_phase=$(json_tool payload-field "${selected_file}" phase) \
    || fail "selected payload has an ineligible phase"

  log "Selected first built payload ${payload_tag} (phase=${payload_phase})"
  extract_rhcos_metadata "${payload_pullspec}" "${coreos_stream_file}"

  rhcos_version=$(json_tool rhcos-version "${coreos_stream_file}") \
    || fail "RHCOS version is missing from installer stream metadata"
  rhcos_ami=$(json_tool rhcos-ami "${coreos_stream_file}" "${RHCOS_AWS_REGION}") \
    || fail "RHCOS AMI is missing for AWS region ${RHCOS_AWS_REGION}"

  [[ "${rhcos_version}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "RHCOS version contains unexpected characters"
  [[ "${rhcos_ami}" =~ ^ami-[0-9a-f]+$ ]] || fail "RHCOS AMI has an invalid format: ${rhcos_ami}"

  write_value "${payload_tag}" "${PAYLOAD_TAG_FILE}"
  write_value "${payload_pullspec}" "${PAYLOAD_PULLSPEC_FILE}"
  write_value "${rhcos_version}" "${RHCOS_VERSION_FILE}"
  write_value "${rhcos_ami}" "${RHCOS_AMI_FILE}"
  write_value "ready" "${STATE_FILE}"

  log "Ready: ocp_version=${TARGET_OCP_Y_STREAM} payload=${payload_tag} rhcos_version=${rhcos_version} aws_region=${RHCOS_AWS_REGION} ami=${rhcos_ami}"
}

main "$@"
