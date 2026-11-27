#!/bin/bash
set -o nounset
set -o pipefail
source "${SHARED_DIR}/capz-test-env.sh"

# Pre-test cleanup: safety net for aborted previous jobs.
# Cleans up any leftover Azure resources (resource groups, ARM resources,
# soft-deleted Key Vaults, AD apps, SPs) before deploying new workload cluster CRs.
# Preserve the persistent CI identity; prefix matching can otherwise select it.
export CLEANUP_EXCLUDED_AD_APP_IDS="6c35b111-a695-4e3d-9f16-229c34bbe53d"
FORCE=1 make clean-azure
FORCE=1 CS_CLUSTER_NAME="${WORKLOAD_CLUSTER_NAME:-capz-tests}" make clean-azure
