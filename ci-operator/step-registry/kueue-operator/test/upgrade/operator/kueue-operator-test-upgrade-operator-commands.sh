#!/bin/bash
set -euo pipefail

source "${SHARED_DIR}/env"

NAMESPACE="openshift-kueue-operator"

if [[ -z "${BUNDLE_IMAGE:-}" ]]; then
  echo "ERROR: BUNDLE_IMAGE not set. Ensure kueue-operator-image-env-setup ran first."
  exit 1
fi

echo "Upgrading kueue operator to CI-built bundle: ${BUNDLE_IMAGE}"

echo "Current operator state before upgrade:"
oc get csv -n "${NAMESPACE}" 2>/dev/null || true
oc get deployment -n "${NAMESPACE}" -o wide 2>/dev/null || true

echo "Removing OLM Subscription and CatalogSource reference..."
OLD_CSV=$(oc get subscription kueue-operator -n "${NAMESPACE}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
oc delete subscription kueue-operator -n "${NAMESPACE}" --ignore-not-found
PATCHED_CSV=""

echo "Installing operator-sdk..."
curl -sLo /tmp/operator-sdk --fail --retry 3 --max-time 120 "https://github.com/operator-framework/operator-sdk/releases/download/v1.39.2/operator-sdk_linux_amd64"
chmod +x /tmp/operator-sdk

echo "Installing CI-built bundle via operator-sdk..."
/tmp/operator-sdk run bundle \
  --timeout=10m \
  --security-context-config restricted \
  --skip-tls-verify \
  -n "${NAMESPACE}" \
  "${BUNDLE_IMAGE}" \
  || {
    echo "Bundle install returned non-zero, falling back to manual upgrade..."

    echo "Applying CRDs from source to ensure schema is up to date..."
    oc apply --server-side --force-conflicts -f bindata/assets/kueue-operator/crds/
    oc apply --server-side --force-conflicts -f deploy/crd/kueue-operator.crd.yaml

    echo "Patching CSV with operator image..."
    PATCHED_CSV=$(oc get csv -n "${NAMESPACE}" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | awk '{print $NF}')
    if [[ -n "${PATCHED_CSV}" && -n "${OPERATOR_IMAGE:-}" ]]; then
      oc patch csv "${PATCHED_CSV}" -n "${NAMESPACE}" --type='json' \
        -p="[{\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/0/image\", \"value\": \"${OPERATOR_IMAGE}\"}]"
    else
      echo "ERROR: Could not patch CSV (PATCHED_CSV=${PATCHED_CSV:-empty}, OPERATOR_IMAGE=${OPERATOR_IMAGE:-empty})"
      exit 1
    fi
  }

if [[ -n "${OLD_CSV}" && "${OLD_CSV}" != "${PATCHED_CSV}" ]]; then
  echo "Cleaning up old CSV: ${OLD_CSV}"
  oc delete csv "${OLD_CSV}" -n "${NAMESPACE}" --ignore-not-found
fi

echo "Waiting for operator deployment to be ready..."
sleep 10
for i in $(seq 1 30); do
  READY=$(oc get deployment openshift-kueue-operator -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "${READY}" -ge 1 ]]; then
    echo "Operator deployment ready after upgrade."
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    echo "ERROR: Operator deployment not ready after 5 minutes"
    oc get deployment -n "${NAMESPACE}" -o yaml 2>/dev/null || true
    oc get pods -n "${NAMESPACE}" 2>/dev/null || true
    exit 1
  fi
  echo "Waiting for operator deployment... ($i/30)"
  sleep 10
done

echo "Waiting for kueue controller-manager..."
oc wait --for=condition=Available deployment/kueue-controller-manager \
  -n "${NAMESPACE}" --timeout=5m

echo "Verifying CRDs are still available..."
for crd in clusterqueues.kueue.x-k8s.io localqueues.kueue.x-k8s.io \
           resourceflavors.kueue.x-k8s.io workloads.kueue.x-k8s.io; do
  if ! oc get crd "$crd" &>/dev/null; then
    echo "ERROR: CRD ${crd} missing after operator upgrade"
    exit 1
  fi
done

echo "Cleaning up stale test namespaces from previous version..."
for ns in $(oc get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E "^kueue-|^e2e-" | grep -v "smoke"); do
  oc delete namespace "$ns" --ignore-not-found 2>/dev/null || true
done

# Re-apply CR matching test/e2e/bindata/assets/08_kueue_default.yaml
# so e2e tests find the expected config after operator upgrade
echo "Re-applying Kueue CR for clean e2e test state..."

DRA_CONFIG=""
if oc api-resources 2>/dev/null | grep -q "deviceclasses"; then
  echo "DRA APIs available, including deviceClassMappings in CR"
  DRA_CONFIG="    resources:
      deviceClassMappings:
      - name: gpu
        deviceClassNames:
        - gpu.example.com
      - name: gpu-late-dc
        deviceClassNames:
        - gpu-late-dc.example.com"
else
  echo "DRA APIs not available, skipping deviceClassMappings"
fi

cat <<EOF | oc apply -f -
apiVersion: kueue.openshift.io/v1
kind: Kueue
metadata:
  name: cluster
  namespace: ${NAMESPACE}
spec:
  managementState: Managed
  config:
    preemption:
      preemptionPolicy: FairSharing
${DRA_CONFIG}
    integrations:
      frameworks:
      - BatchJob
      - Pod
      - Deployment
      - StatefulSet
      - JobSet
      - LeaderWorkerSet
EOF

echo "Waiting for controller-manager to stabilize..."
sleep 10
oc wait --for=condition=Available deployment/kueue-controller-manager \
  -n "${NAMESPACE}" --timeout=5m

echo "Operator upgrade complete."
oc get csv -n "${NAMESPACE}"
oc get deployment -n "${NAMESPACE}" -o wide
