#!/bin/bash
set -o nounset
set -o pipefail
set -o xtrace

source openshift-ci/capz-test-env.sh

# Teardown: Safety net cleanup (post step - always runs)
# Cleans up Azure resources created by the test suite (workload cluster, resource groups).
# The management cluster itself is deprovisioned by the ipi-azure-post chain.
# Cleanup failures should fail the job so we notice orphaned resources.
FORCE=1 make clean-azure
