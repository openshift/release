#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ cluster-tool snapshot ************"
echo "CLUSTER_TOOL_COMMIT: ${CLUSTER_TOOL_COMMIT}"
echo "SNAPSHOT_REGISTRY: ${SNAPSHOT_REGISTRY}"
echo "-------------------------------------------"

FLAVOR_NAME="osac-vmaas"
QUAY_USER=$(cat /var/run/vault/osac-quay-creds/user)

set +x
QUAY_PASS=$(cat /var/run/vault/osac-quay-creds/password)
set -x

timeout -s 9 90m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s \
    "${CLUSTER_TOOL_COMMIT}" \
    "${SNAPSHOT_REGISTRY}" \
    "${FLAVOR_NAME}" \
    "${QUAY_USER}" \
    "${QUAY_PASS}" \
    <<'REMOTE_EOF'
set -euo pipefail

COMMIT="$1"
REGISTRY="$2"
FLAVOR="$3"
QUAY_USER="$4"
QUAY_PASS="$5"

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
set +x
podman login --root /home/cluster-tool/containers/storage \
    "$(echo ${REGISTRY} | cut -d/ -f1)" \
    -u "${QUAY_USER}" -p "${QUAY_PASS}"
set -x

echo "=== Pushing snapshot ==="
python3 /usr/local/bin/cluster-tool push --flavor "${FLAVOR}" --registry "${REGISTRY}"

echo "=== Snapshot push complete ==="
REMOTE_EOF

echo "Snapshot step finished successfully."
