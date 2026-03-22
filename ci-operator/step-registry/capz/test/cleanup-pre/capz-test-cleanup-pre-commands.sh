#!/bin/bash
set -o nounset
set -o pipefail
set -o xtrace

source openshift-ci/capz-test-env.sh

# Pre-test cleanup: safety net for aborted previous jobs.
# Cleans up any leftover Azure resources (resource groups, ARM resources,
# soft-deleted Key Vaults, AD apps, SPs) before deploying new workload cluster CRs.
#
# Two cleanup passes are needed because the gen.sh template uses different
# naming patterns for different resource types:
#   - Managed identities use CAPI_USER prefix: prow-capz-tests-*
#   - Resource group uses WORKLOAD_CLUSTER_NAME: capz-tests-resgroup
#   - Key Vault uses WORKLOAD_CLUSTER_NAME: capz-tests-kv
#
# Both passes run regardless of individual failures; the overall exit code
# reflects whether any pass failed.
rc=0

# Pass 1: Clean resources prefixed with CAPI_USER (managed identities, SPs, apps)
FORCE=1 make clean-azure || rc=$?

# Pass 2: Clean resources using WORKLOAD_CLUSTER_NAME naming (RG, Key Vault)
# The WORKLOAD_CLUSTER_NAME defaults to capz-tests for ARO provider.
WCN="${WORKLOAD_CLUSTER_NAME:-capz-tests}"
./scripts/cleanup-azure-resources.sh \
    --resource-group "${WCN}-resgroup" \
    --prefix "${WCN}" \
    --force || rc=$?

exit $rc
