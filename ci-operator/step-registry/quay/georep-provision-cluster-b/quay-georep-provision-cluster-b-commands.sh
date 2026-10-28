#!/bin/bash
set -euo pipefail

# Provision a HyperShift hosted cluster in the secondary region for
# geo-replication testing. This script does not enable set -x to avoid
# leaking credentials.

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/quay-georep-provision-cluster-b"
mkdir -p "${ARTIFACT_DIR}"

REGION_SECONDARY="${QUAY_GEOREP_REGION_SECONDARY:-us-west-2}"
NODE_COUNT="${QUAY_GEOREP_CLUSTER_B_NODE_COUNT:-3}"
CLUSTER_NAME="quay-georep-b-${NAMESPACE:-ns}-${UNIQUE_HASH:-$(date +%s)}"
CLUSTER_NAME="$(printf '%s' "${CLUSTER_NAME}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-30)"

QUAY_AWS_ACCESS_KEY="$(cat /var/run/quay-qe-aws-secret/access_key)"
QUAY_AWS_SECRET_KEY="$(cat /var/run/quay-qe-aws-secret/secret_key)"
export AWS_ACCESS_KEY_ID="${QUAY_AWS_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${QUAY_AWS_SECRET_KEY}"

PULL_SECRET="${CLUSTER_PROFILE_DIR}/pull-secret"

echo "Provisioning HyperShift hosted cluster '${CLUSTER_NAME}' in ${REGION_SECONDARY}..." >&2

# TODO: Replace with actual hypershift CLI invocation once the HyperShift
# operator is available on the management cluster. This is a placeholder
# that will be filled in during Phase 2 implementation.
#
# Expected flow:
#   1. Install HyperShift operator on management cluster (cluster A)
#   2. Create a HostedCluster CR targeting the secondary region
#   3. Wait for the hosted cluster to become available
#   4. Extract kubeconfig and write to SHARED_DIR
#
# hypershift create cluster aws \
#   --name "${CLUSTER_NAME}" \
#   --region "${REGION_SECONDARY}" \
#   --node-pool-replicas "${NODE_COUNT}" \
#   --pull-secret "${PULL_SECRET}" \
#   --release-image "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" \
#   --aws-creds /var/run/quay-qe-aws-secret/credentials

echo "PLACEHOLDER: HyperShift cluster provisioning not yet implemented" >&2
printf '%s' "${CLUSTER_NAME}" > "${SHARED_DIR}/QUAY_GEOREP_CLUSTER_B_NAME"

echo "Cluster B name: ${CLUSTER_NAME}" >&2
echo "Region: ${REGION_SECONDARY}" >&2
