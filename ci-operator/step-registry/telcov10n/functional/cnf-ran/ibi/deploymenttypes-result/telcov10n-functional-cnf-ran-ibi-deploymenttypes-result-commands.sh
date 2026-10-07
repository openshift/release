#!/bin/bash
set -euo pipefail

main() {
  local result_file="${SHARED_DIR}/ibi-deploymenttypes-exit-code"
  local status
  if [[ -f "${SHARED_DIR}/skip.txt" ]]; then
    echo "Skipping Deployment Types result check."
    return 0
  fi
  if [[ ! -f "${result_file}" ]]; then
    echo "Deployment Types did not record a result; check earlier steps." >&2
    return 1
  fi
  status=$(<"${result_file}")
  if [[ ! "${status}" =~ ^(0|[1-9][0-9]{0,2})$ ]] || (( status > 255 )); then
    echo "Deployment Types recorded an invalid exit code." >&2
    return 1
  fi
  if (( status != 0 )); then
    echo "Deployment Types step failed with exit code ${status}; marking the job failed." >&2
    return 1
  fi
  echo "Deployment Types passed."
}

main "$@"
