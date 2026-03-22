#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

source openshift-ci/capz-test-env.sh

# Teardown: Safety net cleanup (post step - always runs)
# Cleans up Azure resources created by the test suite (workload cluster, resource groups).
# The management cluster itself is deprovisioned by the ipi-azure-post chain.
# Cleanup failures should fail the job so we notice orphaned resources.
#
# Single cleanup pass targeting the workload cluster resource group.
# RG deletion is synchronous — all resources inside are deleted with the RG.
WCN="${WORKLOAD_CLUSTER_NAME:-capz-tests}"
./scripts/cleanup-azure-resources.sh \
    --resource-group "${WCN}-resgroup" \
    --prefix "${WCN}" \
    --force
