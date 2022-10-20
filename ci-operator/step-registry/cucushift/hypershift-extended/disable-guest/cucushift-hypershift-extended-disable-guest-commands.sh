#!/bin/bash

set -xeuo pipefail

if [ ! -f "${SHARED_DIR}/mgmt_kubeconfig" ]; then
  exit 1
fi

echo "switch kubeconfig"
cat "${SHARED_DIR}/mgmt_kubeconfig" > "${SHARED_DIR}/kubeconfig"