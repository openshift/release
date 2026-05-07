#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Running OSAC VMaaS e2e test suite"

timeout -s 9 120m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s "${E2E_NAMESPACE}" "${E2E_VM_TEMPLATE}" "${OSAC_TEST_IMAGE}" <<'REMOTE_EOF'
set -euo pipefail

E2E_NAMESPACE="$1"
E2E_VM_TEMPLATE="$2"
OSAC_TEST_IMAGE="$3"

KUBECONFIG=$(find ${KUBECONFIG} -type f -print -quit 2>/dev/null)
[[ -z "${KUBECONFIG}" ]] && echo "ERROR: No kubeconfig found" && exit 1

PULL_SECRET_PATH="/root/pull-secret"

set +x
podman run --authfile "${PULL_SECRET_PATH}" --rm --network=host \
  -v "${KUBECONFIG}:/root/.kube/config:z" \
  -v "${PULL_SECRET_PATH}:/root/pull-secret:z" \
  -e KUBECONFIG=/root/.kube/config \
  -e OSAC_VM_KUBECONFIG=/root/.kube/config \
  -e OSAC_NAMESPACE="${E2E_NAMESPACE}" \
  -e OSAC_VM_TEMPLATE="${E2E_VM_TEMPLATE}" \
  -e OSAC_PULL_SECRET_PATH=/root/pull-secret \
  "${OSAC_TEST_IMAGE}" \
  make test-vmaas
REMOTE_EOF

echo "VMaaS test suite completed"
