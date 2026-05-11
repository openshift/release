#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


SSH_KEY="/tmp/secrets/edge04/ssh-privatekey"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${SSH_KEY}"

echo "Running full vmaas test suite on ${EDGE04_USER}@${EDGE04_HOST}"

timeout -s 9 150m ssh ${SSH_OPTS} "${EDGE04_USER}@${EDGE04_HOST}" bash -s \
  "${E2E_NAMESPACE}" "${E2E_VM_TEMPLATE}" "${E2E_CLUSTER_TEMPLATE}" "${OSAC_TEST_IMAGE}" <<'REMOTE_EOF'
set -euo pipefail

E2E_NAMESPACE="$1"
E2E_VM_TEMPLATE="$2"
E2E_CLUSTER_TEMPLATE="$3"
OSAC_TEST_IMAGE="$4"

KUBECONFIG=$(find /root -name "kubeconfig" -type f -print -quit 2>/dev/null || echo "")
[[ -z "${KUBECONFIG}" ]] && KUBECONFIG="/root/.kube/config"
[[ ! -f "${KUBECONFIG}" ]] && echo "ERROR: No kubeconfig found at ${KUBECONFIG}" && exit 1

PULL_SECRET_PATH="/root/pull-secret"
WORK_DIR=$(mktemp -d /tmp/osac-test-XXXXXX)

echo "Using kubeconfig: ${KUBECONFIG}"
echo "Work dir: ${WORK_DIR}"
echo "Test image: ${OSAC_TEST_IMAGE}"

set +x
podman run --authfile "${PULL_SECRET_PATH}" --rm --network=host \
  -v "${KUBECONFIG}:/root/.kube/config:z" \
  -v "${PULL_SECRET_PATH}:/root/pull-secret:z" \
  -v "${WORK_DIR}:/reports:z" \
  -e KUBECONFIG=/root/.kube/config \
  -e OSAC_VM_KUBECONFIG=/root/.kube/config \
  -e OSAC_NAMESPACE="${E2E_NAMESPACE}" \
  -e OSAC_VM_TEMPLATE="${E2E_VM_TEMPLATE}" \
  -e OSAC_CLUSTER_TEMPLATE="${E2E_CLUSTER_TEMPLATE}" \
  -e OSAC_PULL_SECRET_PATH=/root/pull-secret \
  "${OSAC_TEST_IMAGE}" \
  make test-vmaas

echo "Copying reports"
cp -r "${WORK_DIR}"/* /tmp/ 2>/dev/null || true
REMOTE_EOF

echo "Test suite completed"
