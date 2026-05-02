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
DIAG_DIR="/tmp/osac-diagnostics"
mkdir -p "${DIAG_DIR}"

echo "$(date +%T) Starting background log collection..."
oc --kubeconfig="${KUBECONFIG}" logs -f deployment/osac-operator-controller-manager -n "${E2E_NAMESPACE}" \
  > "${DIAG_DIR}/operator.log" 2>&1 &
OPERATOR_LOG_PID=$!
oc --kubeconfig="${KUBECONFIG}" logs -f deployment/fulfillment-controller -n "${E2E_NAMESPACE}" \
  > "${DIAG_DIR}/fulfillment-controller.log" 2>&1 &
FC_LOG_PID=$!
oc --kubeconfig="${KUBECONFIG}" logs -f deployment/fulfillment-grpc-server -n "${E2E_NAMESPACE}" \
  > "${DIAG_DIR}/fulfillment-grpc.log" 2>&1 &
GRPC_LOG_PID=$!
oc --kubeconfig="${KUBECONFIG}" logs -f deployment/authorino -n "${E2E_NAMESPACE}" \
  > "${DIAG_DIR}/authorino.log" 2>&1 &
AUTH_LOG_PID=$!

osac_gather() {
  REDACT='s/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/[TOKEN]/g'

  echo ""
  echo "$(date +%T) ========== OSAC MUST-GATHER =========="

  kill "${OPERATOR_LOG_PID}" "${FC_LOG_PID}" "${GRPC_LOG_PID}" "${AUTH_LOG_PID}" 2>/dev/null || true
  wait "${OPERATOR_LOG_PID}" "${FC_LOG_PID}" "${GRPC_LOG_PID}" "${AUTH_LOG_PID}" 2>/dev/null || true

  echo "--- Host memory ---"
  free -h 2>&1 || true

  echo "--- Host dmesg (OOM) ---"
  dmesg 2>&1 | grep -i "oom\|killed process\|out of memory" | tail -10 || echo "no OOM"

  echo "--- VM status ---"
  virsh list --all 2>&1 || true
  for vm in $(virsh list --name 2>/dev/null); do
    echo "--- virsh dommemstat ${vm} ---"
    virsh dommemstat "${vm}" 2>&1 || true
  done

  echo "--- Hub API reachable? ---"
  curl -sk --connect-timeout 5 https://192.168.131.10:6443/readyz 2>&1 || echo "HUB API UNREACHABLE"
  echo ""
  echo "--- Virt API reachable? ---"
  curl -sk --connect-timeout 5 https://192.168.130.10:6443/readyz 2>&1 || echo "VIRT API UNREACHABLE"
  echo ""

  echo "--- OSAC pods ---"
  oc --kubeconfig="${KUBECONFIG}" get pods -n "${E2E_NAMESPACE}" -o wide 2>&1 || true
  echo "--- OSAC deployments ---"
  oc --kubeconfig="${KUBECONFIG}" get deployments -n "${E2E_NAMESPACE}" 2>&1 || true

  echo "--- ComputeInstance CRs ---"
  oc --kubeconfig="${KUBECONFIG}" get computeinstance -n "${E2E_NAMESPACE}" -o yaml 2>&1 | sed -E "${REDACT}" || true
  echo "--- VirtualNetwork CRs ---"
  oc --kubeconfig="${KUBECONFIG}" get virtualnetwork -n "${E2E_NAMESPACE}" -o yaml 2>&1 | sed -E "${REDACT}" || true
  echo "--- Subnet CRs ---"
  oc --kubeconfig="${KUBECONFIG}" get subnet -n "${E2E_NAMESPACE}" -o yaml 2>&1 | sed -E "${REDACT}" || true

  echo "--- Recent events (last 50) ---"
  oc --kubeconfig="${KUBECONFIG}" get events -n "${E2E_NAMESPACE}" --sort-by=.lastTimestamp 2>&1 | tail -50 || true

  echo "--- Cluster operators ---"
  oc --kubeconfig="${KUBECONFIG}" get co 2>&1 || true

  echo "--- Virt cluster VirtualMachines ---"
  oc --kubeconfig=/root/virt-kubeconfig get vm -A 2>&1 || true
  echo "--- Virt cluster VMIs ---"
  oc --kubeconfig=/root/virt-kubeconfig get vmi -A 2>&1 || true
  echo "--- Virt cluster pods not running ---"
  oc --kubeconfig=/root/virt-kubeconfig get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>&1 | head -30 || true

  echo ""
  echo "========== OSAC OPERATOR LOG (full) =========="
  sed -E "${REDACT}" "${DIAG_DIR}/operator.log" 2>/dev/null || echo "no operator log"
  echo ""
  echo "========== FULFILLMENT CONTROLLER LOG (full) =========="
  sed -E "${REDACT}" "${DIAG_DIR}/fulfillment-controller.log" 2>/dev/null || echo "no fulfillment controller log"
  echo ""
  echo "========== FULFILLMENT GRPC LOG (full) =========="
  sed -E "${REDACT}" "${DIAG_DIR}/fulfillment-grpc.log" 2>/dev/null || echo "no grpc log"
  echo ""
  echo "========== AUTHORINO LOG (full) =========="
  sed -E "${REDACT}" "${DIAG_DIR}/authorino.log" 2>/dev/null || echo "no authorino log"

  echo ""
  echo "$(date +%T) ========== END OSAC MUST-GATHER =========="
}

trap osac_gather EXIT

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
