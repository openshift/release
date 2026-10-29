#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

MC_KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"

if [[ ! -f "${MC_KUBECONFIG}" ]]; then
  echo "No MC kubeconfig found at ${MC_KUBECONFIG}, cannot verify HCP health"
  exit 1
fi

# Grace period: wait 2 minutes for pods to restart and stabilize after HO upgrade
echo "Waiting 2 minutes for HO upgrade to stabilize..."
sleep 120

FAILURES=0

# 1. Check HO deployment rollout status
echo "=== Checking HO deployment rollout status ==="
if KUBECONFIG="${MC_KUBECONFIG}" oc rollout status deployment/operator -n hypershift --timeout=300s; then
  echo "PASS: HO deployment rollout is complete"
else
  echo "FAIL: HO deployment rollout did not complete"
  FAILURES=$((FAILURES + 1))
fi

DEPLOYED_IMAGE=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment operator -n hypershift -o jsonpath='{.spec.template.spec.containers[0].image}')
READY_REPLICAS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment operator -n hypershift -o jsonpath='{.status.readyReplicas}')
echo "HO image: ${DEPLOYED_IMAGE}"
echo "Ready replicas: ${READY_REPLICAS:-0}"

if [[ "${READY_REPLICAS:-0}" -lt 1 ]]; then
  echo "FAIL: HO deployment has no ready replicas"
  FAILURES=$((FAILURES + 1))
fi

# 2. Check HostedCluster CRs — verify none are degraded
echo ""
echo "=== Checking HostedCluster health ==="
HC_COUNT=$(KUBECONFIG="${MC_KUBECONFIG}" oc get hostedclusters -A --no-headers 2>/dev/null | wc -l)
echo "Found ${HC_COUNT} HostedCluster(s)"

if [[ "${HC_COUNT}" -gt 0 ]]; then
  KUBECONFIG="${MC_KUBECONFIG}" oc get hostedclusters -A -o wide 2>/dev/null || true

  # Check for degraded HostedClusters
  DEGRADED_HCS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get hostedclusters -A -o json 2>/dev/null \
    | jq -r '.items[] | select(.status.conditions[]? | select(.type == "Degraded" and .status == "True")) | .metadata.namespace + "/" + .metadata.name')

  if [[ -n "${DEGRADED_HCS}" ]]; then
    echo "FAIL: The following HostedClusters are degraded:"
    echo "${DEGRADED_HCS}"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: No HostedClusters are degraded"
  fi
else
  echo "WARN: No HostedClusters found on this MC"
fi

# 3. Check NodePool status — all should remain ready
echo ""
echo "=== Checking NodePool health ==="
NP_COUNT=$(KUBECONFIG="${MC_KUBECONFIG}" oc get nodepools -A --no-headers 2>/dev/null | wc -l)
echo "Found ${NP_COUNT} NodePool(s)"

if [[ "${NP_COUNT}" -gt 0 ]]; then
  KUBECONFIG="${MC_KUBECONFIG}" oc get nodepools -A -o wide 2>/dev/null || true

  # Check for NodePools that are not ready
  NOT_READY_NPS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get nodepools -A -o json 2>/dev/null \
    | jq -r '.items[] | select(.status.conditions[]? | select(.type == "Ready" and .status != "True")) | .metadata.namespace + "/" + .metadata.name')

  if [[ -n "${NOT_READY_NPS}" ]]; then
    echo "FAIL: The following NodePools are not ready:"
    echo "${NOT_READY_NPS}"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS: All NodePools are ready"
  fi
else
  echo "WARN: No NodePools found on this MC"
fi

# 4. Check for excessive pod restarts in hypershift namespace
echo ""
echo "=== Checking pod restarts in hypershift namespace ==="
RESTART_THRESHOLD=10

HIGH_RESTART_PODS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get pods -n hypershift -o json 2>/dev/null \
  | jq -r --argjson threshold "${RESTART_THRESHOLD}" \
    '.items[] | select(.status.containerStatuses[]? | .restartCount > $threshold) | .metadata.name + " (restarts: " + (.status.containerStatuses[] | select(.restartCount > $threshold) | .restartCount | tostring) + ")"')

if [[ -n "${HIGH_RESTART_PODS}" ]]; then
  echo "FAIL: Pods with excessive restarts (>${RESTART_THRESHOLD}):"
  echo "${HIGH_RESTART_PODS}"
  FAILURES=$((FAILURES + 1))
else
  echo "PASS: No pods have excessive restarts in hypershift namespace"
fi

# Summary
echo ""
echo "=== HCP Health Verification Summary ==="
if [[ "${FAILURES}" -gt 0 ]]; then
  echo "RESULT: FAILED (${FAILURES} check(s) failed)"
  exit 1
else
  echo "RESULT: PASSED — all HCPs remain healthy after HO upgrade"
fi
