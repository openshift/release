#!/bin/bash

set -euo pipefail

readonly RELEASE_PAYLOAD_AUTH_FILE="${RELEASE_PAYLOAD_AUTH_FILE:-/etc/pull-secret/.dockerconfigjson}"
readonly RHCOS_AWS_REGION="${RHCOS_AWS_REGION:-us-east-1}"
readonly PYTHON_BIN="${PYTHON_BIN:-python3}"
readonly OC_BIN="${OC_BIN:-oc}"
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

validate_settings() {
  [[ -n "${RELEASE_IMAGE_LATEST:-}" ]] || fail "RELEASE_IMAGE_LATEST is required"
  [[ "${RELEASE_IMAGE_LATEST}" != *[[:space:]]* ]] || fail "RELEASE_IMAGE_LATEST must not contain whitespace"
  [[ -s "${RELEASE_PAYLOAD_AUTH_FILE}" ]] \
    || fail "release payload auth file is missing or empty: ${RELEASE_PAYLOAD_AUTH_FILE}"

  mkdir -p "${SHARED_DIR}" "${ARTIFACT_DIR}"
  require_command "${OC_BIN}"
  require_command "${PYTHON_BIN}"
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

if action == "release-version":
    nested_string(data, ("metadata", "version"))
elif action == "rhcos-version":
    nested_string(data, ("architectures", "x86_64", "artifacts", "metal", "release"))
elif action == "rhcos-ami":
    nested_string(data, ("architectures", "x86_64", "images", "aws", "regions", sys.argv[3], "image"))
else:
    print("unknown JSON action: {}".format(action), file=sys.stderr)
    sys.exit(2)
PYTHON
}

extract_rhcos_metadata() {
  local pullspec="$1"
  local coreos_stream_file="$2"
  local installer_dir
  local installer_bin

  if [[ -n "${ROSA_MARKETPLACE_INSTALLER_BIN:-}" ]]; then
    installer_bin="${ROSA_MARKETPLACE_INSTALLER_BIN}"
  else
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
  local release_info_file="${ARTIFACT_DIR}/rosa-marketplace-release-info.json"
  local coreos_stream_file="${ARTIFACT_DIR}/rosa-marketplace-coreos-stream.json"
  local payload_version
  local ocp_y_stream
  local rhcos_version
  local rhcos_ami

  validate_settings

  "${OC_BIN}" adm release info \
    -a "${RELEASE_PAYLOAD_AUTH_FILE}" \
    -o json \
    "${RELEASE_IMAGE_LATEST}" > "${release_info_file}"

  payload_version=$(json_tool release-version "${release_info_file}") \
    || fail "release payload metadata does not contain a version"
  [[ "${payload_version}" =~ ^([0-9]+\.[0-9]+)\.[0-9]+([-+.][A-Za-z0-9._+-]+)?$ ]] \
    || fail "release payload version has an invalid format"
  ocp_y_stream="${BASH_REMATCH[1]}"

  log "Processing release-controller payload version=${payload_version}"
  extract_rhcos_metadata "${RELEASE_IMAGE_LATEST}" "${coreos_stream_file}"

  rhcos_version=$(json_tool rhcos-version "${coreos_stream_file}") \
    || fail "RHCOS version is missing from installer stream metadata"
  rhcos_ami=$(json_tool rhcos-ami "${coreos_stream_file}" "${RHCOS_AWS_REGION}") \
    || fail "RHCOS AMI is missing for AWS region ${RHCOS_AWS_REGION}"

  [[ "${rhcos_version}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "RHCOS version contains unexpected characters"
  [[ "${rhcos_ami}" =~ ^ami-[0-9a-f]+$ ]] || fail "RHCOS AMI has an invalid format: ${rhcos_ami}"

  write_value "${ocp_y_stream}" "${OCP_VERSION_FILE}"
  write_value "${payload_version}" "${PAYLOAD_TAG_FILE}"
  write_value "${RELEASE_IMAGE_LATEST}" "${PAYLOAD_PULLSPEC_FILE}"
  write_value "${rhcos_version}" "${RHCOS_VERSION_FILE}"
  write_value "${rhcos_ami}" "${RHCOS_AMI_FILE}"
  write_value "ready" "${STATE_FILE}"

  log "Ready: ocp_version=${ocp_y_stream} payload=${payload_version} rhcos_version=${rhcos_version} aws_region=${RHCOS_AWS_REGION} ami=${rhcos_ami}"
}

main "$@"
