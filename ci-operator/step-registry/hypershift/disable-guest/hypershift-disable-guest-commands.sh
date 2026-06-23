#!/bin/bash

set -xeuo pipefail

if [ ! -f "${SHARED_DIR}/mgmt_kubeconfig" ]; then
  echo "ERROR: ${SHARED_DIR}/mgmt_kubeconfig not found, cannot switch back to management cluster" >&2
  exit 1
fi

echo "switch kubeconfig"
cat "${SHARED_DIR}/mgmt_kubeconfig" > "${SHARED_DIR}/kubeconfig"
