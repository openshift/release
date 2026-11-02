#!/bin/bash
set -euo pipefail

if [[ -f "${SHARED_DIR}/skip-work-steps" ]]; then
  echo "Skipping work step: skip-work-steps marker is present."
  exit 0
fi
export TEST_FEATURES=nvidiagpu
export TEST_LABELS=nvidia-ci,gpu
export TEST_VERBOSE=true
export NVIDIAGPU_CLEANUP=false
export NVIDIAGPU_DEPLOY_FROM_BUNDLE=false
export NVIDIAGPU_GPU_CLUSTER_POLICY_PATCH='[{"op": "add", "path": "/spec/driver/rdma", "value": {"enabled": true} }]'
make run-tests
