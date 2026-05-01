#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Running OSAC E2E test (golden): ${TEST}"

timeout -s 9 60m ssh -F "${SHARED_DIR}/ssh_config" ci_machine bash -s "${TEST}" "${E2E_NAMESPACE}" "${E2E_VM_TEMPLATE}" "${E2E_CLUSTER_TEMPLATE}" "${OSAC_TEST_IMAGE}" <<'REMOTE_EOF'
set -euo pipefail

TEST="$1"
E2E_NAMESPACE="$2"
E2E_VM_TEMPLATE="$3"
E2E_CLUSTER_TEMPLATE="$4"
OSAC_TEST_IMAGE="$5"

KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
[[ ! -f "${KUBECONFIG}" ]] && echo "ERROR: No kubeconfig found at ${KUBECONFIG}" && exit 1

PULL_SECRET_PATH="/root/pull-secret"

dump_diagnostics() {
  echo ""
  echo "$(date +%T) ========== POST-FAILURE DIAGNOSTICS =========="
  echo "--- Host memory ---"
  free -h 2>&1 || true
  echo "--- Hub API reachable? ---"
  curl -sk --connect-timeout 5 https://192.168.131.10:6443/readyz 2>&1 || echo "HUB API UNREACHABLE"
  echo ""
  echo "--- Virt API reachable? ---"
  curl -sk --connect-timeout 5 https://192.168.130.10:6443/readyz 2>&1 || echo "VIRT API UNREACHABLE"
  echo ""
  echo "--- OSAC pods ---"
  oc --kubeconfig="${KUBECONFIG}" get pods -n "${E2E_NAMESPACE}" 2>&1 || true
  echo "--- OSAC deployments ---"
  oc --kubeconfig="${KUBECONFIG}" get deployments -n "${E2E_NAMESPACE}" 2>&1 || true
  echo "--- Recent events ---"
  oc --kubeconfig="${KUBECONFIG}" get events -n "${E2E_NAMESPACE}" --sort-by=.lastTimestamp 2>&1 | tail -30 || true
  echo "--- OSAC operator logs (last 50) ---"
  oc --kubeconfig="${KUBECONFIG}" logs deployment/osac-operator-controller-manager -n "${E2E_NAMESPACE}" --tail=50 2>&1 || true
  echo "--- Fulfillment controller logs (last 30) ---"
  oc --kubeconfig="${KUBECONFIG}" logs deployment/fulfillment-controller -n "${E2E_NAMESPACE}" --tail=30 2>&1 || true
  echo "--- Fulfillment gRPC server logs (last 30) ---"
  oc --kubeconfig="${KUBECONFIG}" logs deployment/fulfillment-grpc-server -n "${E2E_NAMESPACE}" --tail=30 2>&1 || true
  echo "--- Authorino logs (last 30) ---"
  oc --kubeconfig="${KUBECONFIG}" logs deployment/authorino -n "${E2E_NAMESPACE}" --tail=30 2>&1 || true
  echo "--- Host dmesg (OOM) ---"
  dmesg 2>&1 | grep -i "oom\|killed process\|out of memory" | tail -10 || echo "no OOM"
  echo "--- VM status ---"
  virsh list --all 2>&1 || true
  echo "$(date +%T) ========== END DIAGNOSTICS =========="
}

trap dump_diagnostics ERR

set +x
podman run --authfile "${PULL_SECRET_PATH}" --rm --network=host \
  -v "${KUBECONFIG}:/root/.kube/config:z" \
  -v "${PULL_SECRET_PATH}:/root/pull-secret:z" \
  -v "/root/virt-kubeconfig:/root/virt-kubeconfig:z" \
  -e KUBECONFIG=/root/.kube/config \
  -e OSAC_VM_KUBECONFIG=/root/virt-kubeconfig \
  -e OSAC_NAMESPACE="${E2E_NAMESPACE}" \
  -e OSAC_VM_TEMPLATE="${E2E_VM_TEMPLATE}" \
  -e OSAC_CLUSTER_TEMPLATE="${E2E_CLUSTER_TEMPLATE}" \
  -e OSAC_PULL_SECRET_PATH=/root/pull-secret \
  "${OSAC_TEST_IMAGE}" \
  make test TEST="${TEST}"
REMOTE_EOF

echo "Test completed"
