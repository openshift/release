#!/bin/bash

set -euo pipefail

# Track timing for metrics collection
SECONDS=0
NODE_WAIT_START=$SECONDS

# Wait for all nodes to be Ready
oc wait --for=condition=Ready nodes --all --timeout=4m
NODE_WAIT_DURATION=$((SECONDS - NODE_WAIT_START))

# ServiceAccount controller health check with continuous CSR approval
# Workaround for MCO CSR renewal timing gap on long-idle clusters
# Kube-controller-manager needs time to sync informer caches before
# the SA controller can process namespace events
SA_CHECK_START=$SECONDS
SA_TIMEOUT=600  # 10 minutes per analysis of 14-day CI data

oc create namespace ci-preflight

echo "Waiting for ServiceAccount controller (with continuous CSR approval)..."
# Wait for default ServiceAccount to be auto-created by SA controller
# Approve any pending CSRs during the wait to unblock kubelet communication
if ! timeout "${SA_TIMEOUT}" bash -c '
  until oc get serviceaccount default -n ci-preflight &>/dev/null; do
    # Approve any pending CSRs while waiting
    PENDING=$(oc get csr --no-headers 2>/dev/null | awk '\''$6=="Pending" {print $1}'\'' || true)
    if [[ -n "$PENDING" ]]; then
      echo "Approving $(echo "$PENDING" | wc -l) pending CSR(s)..."
      echo "$PENDING" | xargs oc adm certificate approve 2>/dev/null || true
    fi
    sleep 5
  done
'; then
    SA_CHECK_DURATION=$((SECONDS - SA_CHECK_START))
    echo "FATAL: ServiceAccount controller not operational after ${SA_CHECK_DURATION}s"
    echo "Cluster SA controller failed to recover"
    echo ""
    oc get nodes -o wide || true
    oc get co || true
    oc get csr || true
    exit 1
fi

SA_CHECK_DURATION=$((SECONDS - SA_CHECK_START))
TOTAL_DURATION=$SECONDS

# Cleanup
oc delete namespace ci-preflight --wait=false || true

# Metrics for analysis (required for timeout tuning)
echo "Preflight health check summary:"
echo "  Node readiness: ${NODE_WAIT_DURATION}s"
echo "  SA controller recovery (with CSR approval): ${SA_CHECK_DURATION}s"
echo "  Total preflight duration: ${TOTAL_DURATION}s"
