#!/bin/bash
set -o nounset
set -o pipefail
set -o xtrace

source openshift-ci/capz-test-env.sh

# Pre-test cleanup: safety net for aborted previous jobs.
# Cleans up any leftover Azure resources (resource groups, ARM resources,
# soft-deleted Key Vaults, AD apps, SPs) before deploying new workload cluster CRs.
FORCE=1 make clean-azure
