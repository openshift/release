#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}"
}

results_count=$(find "${SHARED_DIR}" -name "test_results_*" -type f | wc -l)
if [ "${results_count}" == "0" ]; then
  log "ERROR: Failed to find any test results, tests must have failed early"
  exit 100
fi

failures=0
for file in "${SHARED_DIR}"/test_results_*; do
  if [[ -f "${file}" ]]; then
    test_exit="$(cat "${file}")"
    if [ "${test_exit}" != "0" ]; then
      log "INFO: Failure found in file ${file}"
      failures=$((failures+1))
    fi
  fi
done

if [ "${failures}" != "0" ]; then
  log "INFO: ${failures} failure(s) were found"
  exit 1
fi
