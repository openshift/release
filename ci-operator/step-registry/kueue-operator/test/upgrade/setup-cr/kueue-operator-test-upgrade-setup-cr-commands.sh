#!/bin/bash
set -euo pipefail

NAMESPACE="openshift-kueue-operator"

echo "Patching operator CSV with CI image..."
source "${SHARED_DIR}/env"
if [[ -n "${OPERATOR_IMAGE:-}" ]]; then
  CSV=$(oc get csv -n "${NAMESPACE}" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | awk '{print $NF}')
  if [[ -n "${CSV}" ]]; then
    oc patch csv -n "${NAMESPACE}" "${CSV}" --type=json \
      -p="[{\"op\": \"replace\", \"path\": \"/spec/install/spec/deployments/0/spec/template/spec/containers/0/image\", \"value\": \"${OPERATOR_IMAGE}\"}]"
  fi
fi

echo "Waiting for operator deployment..."
for i in $(seq 1 30); do
  READY=$(oc get deployment openshift-kueue-operator -n "${NAMESPACE}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  DESIRED=$(oc get deployment openshift-kueue-operator -n "${NAMESPACE}" \
    -o jsonpath='{.status.replicas}' 2>/dev/null || echo "1")
  # Accept any ready replica — ImageDigestMirrorSet may not propagate to all nodes
  if [[ "${READY}" -ge 1 ]]; then
    echo "Operator deployment ready (${READY}/${DESIRED} replicas)."
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    echo "ERROR: Operator deployment not ready after 5 minutes"
    oc get deployment -n "${NAMESPACE}" -o wide 2>/dev/null || true
    oc get pods -n "${NAMESPACE}" 2>/dev/null || true
    exit 1
  fi
  echo "Waiting for operator deployment... (ready=$READY/$DESIRED, $i/30)"
  sleep 10
done

echo "Creating default Kueue CR..."
oc apply -f - <<EOF
apiVersion: kueue.openshift.io/v1
kind: Kueue
metadata:
  name: cluster
  namespace: ${NAMESPACE}
spec:
  managementState: Managed
  config:
    integrations:
      frameworks:
      - BatchJob
      - Pod
      - Deployment
      - StatefulSet
      - JobSet
      - LeaderWorkerSet
EOF

echo "Waiting for kueue CRDs..."
for i in $(seq 1 30); do
  if oc get crd clusterqueues.kueue.x-k8s.io &>/dev/null && \
     oc get crd localqueues.kueue.x-k8s.io &>/dev/null && \
     oc get crd resourceflavors.kueue.x-k8s.io &>/dev/null && \
     oc get crd workloads.kueue.x-k8s.io &>/dev/null; then
    echo "Kueue CRDs available."
    break
  fi
  echo "Waiting for CRDs... ($i/30)"
  sleep 10
done

for crd in clusterqueues.kueue.x-k8s.io localqueues.kueue.x-k8s.io resourceflavors.kueue.x-k8s.io workloads.kueue.x-k8s.io; do
  if ! oc get crd "$crd" &>/dev/null; then
    echo "ERROR: CRD ${crd} not found"
    oc get kueue cluster -n "${NAMESPACE}" -o yaml 2>/dev/null || true
    oc logs -n "${NAMESPACE}" deployment/openshift-kueue-operator --tail=30 2>/dev/null || true
    exit 1
  fi
done

echo "Kueue CR created and CRDs available."
oc get csv -n "${NAMESPACE}"
