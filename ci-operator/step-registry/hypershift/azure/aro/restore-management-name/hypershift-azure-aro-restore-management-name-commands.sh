#!/bin/bash
set -euo pipefail
if [[ -f "${SHARED_DIR}/aro-management-cluster-name" ]]; then
  cp "${SHARED_DIR}/aro-management-cluster-name" "${SHARED_DIR}/cluster-name"
fi
