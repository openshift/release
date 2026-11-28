#!/bin/bash

set -euo pipefail

DEBUG_WAIT_TIMEOUT="${DEBUG_WAIT_TIMEOUT:-0}"

if [[ "${DEBUG_WAIT_TIMEOUT}" -gt 0 ]] 2>/dev/null; then
  echo "Debug wait: sleeping for ${DEBUG_WAIT_TIMEOUT} seconds for debugging..."
  echo "Management cluster KUBECONFIG: ${KUBECONFIG}"
  echo "Hosted cluster KUBECONFIG: ${SHARED_DIR}/nested_kubeconfig"
  oc get nodes 2>/dev/null || true
  sleep "${DEBUG_WAIT_TIMEOUT}"
  echo "Debug wait complete."
else
  echo "DEBUG_WAIT_TIMEOUT is 0 or unset, skipping debug wait."
fi
