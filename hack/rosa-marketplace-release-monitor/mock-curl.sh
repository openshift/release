#!/bin/bash

set -euo pipefail

destination=""
url=""

while (( $# > 0 )); do
  case "$1" in
    --output)
      destination="$2"
      shift 2
      ;;
    --max-filesize)
      [[ "$2" == "${TEST_EXPECTED_MAX_FILESIZE:-10485760}" ]]
      shift 2
      ;;
    --write-out|--connect-timeout|--max-time)
      shift 2
      ;;
    --silent|--show-error|--location)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

[[ -n "${destination}" && -n "${url}" ]]

if [[ "${url}" == */config ]]; then
  config_attempt=1
  if [[ -n "${TEST_CONFIG_ATTEMPT_FILE:-}" ]]; then
    if [[ -s "${TEST_CONFIG_ATTEMPT_FILE}" ]]; then
      config_attempt=$(( $(<"${TEST_CONFIG_ATTEMPT_FILE}") + 1 ))
    fi
    printf '%s\n' "${config_attempt}" > "${TEST_CONFIG_ATTEMPT_FILE}"
  fi
  if (( config_attempt <= ${TEST_CONFIG_TRANSIENT_FAILURES:-0} )); then
    printf 'transient failure\n' > "${destination}"
    printf '503'
    exit 0
  fi
  printf '%s' "${TEST_CONFIG_HTTP_CODE:-200}"
  if [[ "${TEST_CONFIG_HTTP_CODE:-200}" == "200" ]]; then
    cp "${TEST_CONFIG_FIXTURE}" "${destination}"
  else
    printf 'stream unavailable\n' > "${destination}"
  fi
elif [[ "${url}" == */tags ]]; then
  printf '%s' "${TEST_TAGS_HTTP_CODE:-200}"
  if [[ "${TEST_TAGS_HTTP_CODE:-200}" == "200" ]]; then
    cp "${TEST_TAGS_FIXTURE}" "${destination}"
  else
    printf 'tags unavailable\n' > "${destination}"
  fi
else
  printf 'unexpected URL: %s\n' "${url}" >&2
  exit 2
fi
