#!/bin/bash

set -euo pipefail

status_file="${SHARED_DIR}/quay-pr-smoke-playwright-status"
if [[ ! -s "${status_file}" ]]; then
  echo "Playwright did not defer a result; preserving any earlier step failure"
  exit 0
fi

status="$(< "${status_file}")"
if [[ ! "${status}" =~ ^[0-9]+$ ]] || (( status > 255 )); then
  echo "Invalid deferred Playwright status: ${status}" >&2
  exit 1
fi
if (( status != 0 )); then
  echo "Returning deferred Playwright failure status ${status}" >&2
  exit "${status}"
fi

echo "Playwright passed"
