#!/bin/bash

set -xeuo pipefail

echo "switch kubeconfig"
cat "${SHARED_DIR}/temp_kubeconfig" > "${SHARED_DIR}/kubeconfig"