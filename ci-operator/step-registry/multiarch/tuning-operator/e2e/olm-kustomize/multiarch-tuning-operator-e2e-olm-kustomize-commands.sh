#!/bin/bash
export CLEANUP=true
# execute the slow tests only on one of the runs (choose randomly)
if [ $((RANDOM % 100)) -lt 50 ]; then
  export GINKGO_EXTRA_ARGS="--skip=\\[slow-30\\]"
  echo "[SKIP] Skipping slow tests in the OLM deployment"
fi
USE_OLM=true ./hack/deploy-and-e2e.sh
if [ "${GINKGO_EXTRA_ARGS}" == "" ]; then
  export GINKGO_EXTRA_ARGS="--skip=\\[slow-30\\]"
  echo "[SKIP] Skipping slow tests in the Kustomize deployment"
else
  GINKGO_EXTRA_ARGS=""
fi
USE_OLM=false ./hack/deploy-and-e2e.sh