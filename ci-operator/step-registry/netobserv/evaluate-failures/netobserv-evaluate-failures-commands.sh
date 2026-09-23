#!/bin/bash

set -uo pipefail

FAILURES_FILE="${SHARED_DIR}/netobserv-step-failures"

if [[ -f "${FAILURES_FILE}" ]]; then
  echo "====> The following test steps failed:"
  while IFS= read -r line; do
    echo "  - ${line}"
  done < "${FAILURES_FILE}"
  exit 1
fi

echo "====> All test steps passed"
