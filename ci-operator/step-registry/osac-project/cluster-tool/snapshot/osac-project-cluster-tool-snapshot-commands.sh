#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ cluster-tool snapshot ************"
echo "CLUSTER_TOOL_COMMIT: ${CLUSTER_TOOL_COMMIT}"
echo "SNAPSHOT_REGISTRY: ${SNAPSHOT_REGISTRY}"
echo "SNAPSHOT_TAG: ${SNAPSHOT_TAG}"
echo "-------------------------------------------"

FLAVOR_NAME="${SNAPSHOT_TAG}"
QUAY_USER=$(cat /var/run/vault/osac-quay-creds/user)

QUAY_PASS=$(cat /var/run/vault/osac-quay-creds/password)

timeout -s 9 90m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s \
    "${CLUSTER_TOOL_COMMIT}" \
    "${SNAPSHOT_REGISTRY}" \
    "${SNAPSHOT_TAG}" \
    "${FLAVOR_NAME}" \
    "${QUAY_USER}" \
    "${QUAY_PASS}" \
    <<'REMOTE_EOF'
set -euo pipefail

COMMIT="$1"
REGISTRY="$2"
TAG="$3"
FLAVOR="$4"
QUAY_USER="$5"
QUAY_PASS="$6"

echo "=== Installing cluster-tool ==="
curl -fsSL "https://raw.githubusercontent.com/omer-vishlitzky/cluster-tool/${COMMIT}/cluster-tool" \
    -o /usr/local/bin/cluster-tool
chmod +x /usr/local/bin/cluster-tool

echo "=== Setting up cluster-tool ==="
python3 /usr/local/bin/cluster-tool connect ci --host local --data-path /home/cluster-tool

echo "=== Discovering cluster ID ==="
CLUSTER_ID=$(virsh list --name | grep test-infra-cluster | sed 's/test-infra-cluster-//;s/-master-0//' | head -1)
[[ -z "${CLUSTER_ID}" ]] && echo "ERROR: No running test-infra cluster found" && exit 1
echo "Found cluster ID: ${CLUSTER_ID}"

echo "=== Creating snapshot ==="
python3 /usr/local/bin/cluster-tool snapshot --name "${FLAVOR}" --source "${CLUSTER_ID}"

echo "=== Authenticating to registry ==="
printf '%s' "${QUAY_PASS}" | podman login "$(echo "${REGISTRY}" | cut -d/ -f1)" \
    -u "${QUAY_USER}" --password-stdin

echo "=== Pushing snapshot ==="
python3 /usr/local/bin/cluster-tool push "${FLAVOR}" --registry "${REGISTRY}" --tag "${TAG}"

echo "=== Snapshot push complete ==="
REMOTE_EOF

echo "Snapshot step finished successfully."
