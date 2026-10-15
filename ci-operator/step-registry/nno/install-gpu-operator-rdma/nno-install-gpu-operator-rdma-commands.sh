#!/bin/bash
set -euo pipefail
export TEST_FEATURES=nvidiagpu
export TEST_LABELS=nvidia-ci,gpu
export TEST_VERBOSE=true
export NVIDIAGPU_CLEANUP=false
export NVIDIAGPU_DEPLOY_FROM_BUNDLE=false
export NVIDIAGPU_GPU_CLUSTER_POLICY_PATCH='[{"op": "add", "path": "/spec/driver/rdma", "value": {"enabled": true} }]'
make run-tests
