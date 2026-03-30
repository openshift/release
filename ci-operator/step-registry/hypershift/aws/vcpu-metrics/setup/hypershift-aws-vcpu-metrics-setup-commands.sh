#!/bin/bash
set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/management_cluster_kubeconfig"

echo "=== Step 1: Patch HyperShift Operator Image ==="
if [[ -n "${OVERRIDE_HO_IMAGE:-}" ]]; then
  echo "Patching HO deployment with image: ${OVERRIDE_HO_IMAGE}"
  oc -n hypershift set image deployment/operator operator="${OVERRIDE_HO_IMAGE}"
  echo "Waiting for rollout..."
  oc -n hypershift rollout status deployment/operator --timeout=300s
  ACTUAL_IMAGE=$(oc -n hypershift get deployment/operator -o jsonpath='{.spec.template.spec.containers[0].image}')
  echo "HO deployment now running: ${ACTUAL_IMAGE}"
  if [[ "${ACTUAL_IMAGE}" != "${OVERRIDE_HO_IMAGE}" ]]; then
    echo "[FAIL] HO image mismatch: expected ${OVERRIDE_HO_IMAGE}, got ${ACTUAL_IMAGE}"
    exit 1
  fi
  echo "[PASS] HO image override successful"
else
  echo "No OVERRIDE_HO_IMAGE set, using default CI image"
  ACTUAL_IMAGE=$(oc -n hypershift get deployment/operator -o jsonpath='{.spec.template.spec.containers[0].image}')
  echo "HO deployment running: ${ACTUAL_IMAGE}"
fi

echo ""
echo "=== Step 2: Create rosa-cpus-instance-types-config ConfigMap ==="
# This ConfigMap provides vCPU fallback values for instance types that
# the EC2 DescribeInstanceTypes API might not recognize on the MC account.
# We include real instance type values so the verify step can confirm
# the ConfigMap path works when EC2 returns an unknown type.
oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: rosa-cpus-instance-types-config
  namespace: hypershift
data:
  # Known instance types (matches EC2 API values for cross-check)
  m5.xlarge: "4"
  m5.2xlarge: "8"
  m5.4xlarge: "16"
  m6i.xlarge: "4"
  m6i.2xlarge: "8"
  # Instance types that EC2 API may not recognize on MC accounts
  p4de.24xlarge: "96"
  i3.metal: "72"
  g6.xlarge: "4"
  g6.2xlarge: "8"
  # Canary entry for verify step to detect ConfigMap is loaded
  test-canary.xlarge: "42"
EOF
echo "[PASS] ConfigMap rosa-cpus-instance-types-config created"

echo ""
echo "=== Step 3: Verify HO is healthy after setup ==="
oc -n hypershift wait --for=condition=Available deployment/operator --timeout=120s
HO_READY=$(oc -n hypershift get deployment/operator -o jsonpath='{.status.readyReplicas}')
echo "HO ready replicas: ${HO_READY}"
if [[ "${HO_READY}" -lt 1 ]]; then
  echo "[FAIL] HO has no ready replicas"
  exit 1
fi
echo "[PASS] HO is healthy"
