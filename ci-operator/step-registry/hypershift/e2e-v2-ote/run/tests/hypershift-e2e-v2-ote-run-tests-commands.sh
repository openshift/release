#!/bin/bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"

/hypershift/bin/hypershift-tests-ext run \
  --shared-dir="${SHARED_DIR}" \
  --artifact-dir="${ARTIFACT_DIR}"
