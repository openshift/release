#!/bin/bash

set -xeuo pipefail

echo "switch kubeconfig"
cat "${SHARED_DIR}/mgmt_kubeconfig" > "${SHARED_DIR}/kubeconfig"