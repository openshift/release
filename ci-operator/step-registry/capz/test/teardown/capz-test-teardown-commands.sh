#!/bin/bash
set -o nounset
set -o pipefail
set -o xtrace

source openshift-ci/capz-test-env.sh

# Teardown: Safety net cleanup (post step - always runs)
# Cleans up Azure resources created by the test suite (workload cluster, resource groups).
# The management cluster itself is deprovisioned by the ipi-azure-post chain.
# Cleanup failures should fail the job so we notice orphaned resources.
#
# Two passes needed: gen.sh overrides CS_CLUSTER_NAME with WORKLOAD_CLUSTER_NAME,
# so resources end up under a different prefix than what CS_CLUSTER_NAME defaults to.
# See: https://github.com/stolostron/capi-tests/issues/627
FORCE=1 make clean-azure
FORCE=1 CS_CLUSTER_NAME="${WORKLOAD_CLUSTER_NAME:-capz-tests}" make clean-azure
