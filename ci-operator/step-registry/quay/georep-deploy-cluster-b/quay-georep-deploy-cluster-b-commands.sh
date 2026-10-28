#!/bin/bash
set -euo pipefail

# Deploy Quay on cluster B for geo-replication. Uses the kubeconfig from
# the provision-cluster-b step and the shared geo-rep storage config.
# This script does not enable set -x to protect credentials.

KUBECONFIG_B="${SHARED_DIR}/kubeconfig-cluster-b"
if [[ ! -s "${KUBECONFIG_B}" ]]; then
    echo "ERROR: ${KUBECONFIG_B} not found; quay-georep-provision-cluster-b must run first." >&2
    exit 1
fi

GEOREP_STORAGE_CONFIG="${SHARED_DIR}/quay-storage-config.yaml"
if [[ ! -s "${GEOREP_STORAGE_CONFIG}" ]]; then
    echo "ERROR: ${GEOREP_STORAGE_CONFIG} not found; quay-georep-provision-storage must run first." >&2
    exit 1
fi

# TODO: Implement Quay deployment on cluster B.
#
# Expected flow:
#   1. Export KUBECONFIG="${KUBECONFIG_B}" to target cluster B
#   2. Create quay-enterprise namespace
#   3. Install Quay Operator via OLM Subscription
#   4. Wait for CSV to succeed
#   5. Create config-bundle-secret merging:
#      - geo-rep storage config (both locations)
#      - database config from ${SHARED_DIR}/quay-database-aws-rds-config.yaml
#      - FEATURE_STORAGE_REPLICATION: true
#   6. Create QuayRegistry CR
#   7. Wait for Available=True
#
# The secondary site should prefer the secondary storage location.

echo "PLACEHOLDER: Quay deployment on cluster B not yet implemented" >&2
echo "Would use kubeconfig: ${KUBECONFIG_B}" >&2
echo "Would use geo-rep storage config: ${GEOREP_STORAGE_CONFIG}" >&2
