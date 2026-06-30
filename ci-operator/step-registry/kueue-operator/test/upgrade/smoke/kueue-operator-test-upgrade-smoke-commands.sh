#!/bin/bash
set -euo pipefail

SMOKE_NS="kueue-upgrade-smoke"

cleanup() {
  echo "Cleaning up smoke test resources..."
  oc delete job smoke-job -n "${SMOKE_NS}" --ignore-not-found 2>/dev/null || true
  oc delete localqueue smoke-lq -n "${SMOKE_NS}" --ignore-not-found 2>/dev/null || true
  oc delete clusterqueue smoke-cq --ignore-not-found 2>/dev/null || true
  oc delete resourceflavor smoke-flavor --ignore-not-found 2>/dev/null || true
  oc delete namespace "${SMOKE_NS}" --ignore-not-found 2>/dev/null || true
}
trap cleanup EXIT

echo "Running post-upgrade smoke test..."

NAMESPACE="openshift-kueue-operator"

echo "Waiting for kueue controller-manager deployment to exist..."
for i in $(seq 1 60); do
  if oc get deployment kueue-controller-manager -n "${NAMESPACE}" &>/dev/null; then
    echo "Controller-manager deployment found."
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "ERROR: kueue-controller-manager deployment not found after 10 minutes"
    oc get deployments -n "${NAMESPACE}" 2>/dev/null || true
    exit 1
  fi
  echo "Waiting for controller-manager deployment to be created... ($i/60)"
  sleep 10
done

echo "Waiting for kueue controller-manager to be available..."
oc wait --for=condition=Available deployment/kueue-controller-manager \
  -n "${NAMESPACE}" --timeout=5m

echo "Waiting for kueue webhook endpoints to be ready..."
for i in $(seq 1 30); do
  ENDPOINTS=$(oc get endpoints kueue-webhook-service -n "${NAMESPACE}" \
    -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
  if [[ -n "${ENDPOINTS}" ]]; then
    echo "Webhook endpoints ready: ${ENDPOINTS}"
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    echo "ERROR: Webhook endpoints not ready after 5 minutes"
    oc get endpoints -n "${NAMESPACE}" 2>/dev/null || true
    exit 1
  fi
  echo "Waiting for webhook endpoints... ($i/30)"
  sleep 10
done

oc create namespace "${SMOKE_NS}" 2>/dev/null || true
oc label ns "${SMOKE_NS}" kueue.openshift.io/managed=true --overwrite

oc apply -f - <<EOF
apiVersion: kueue.x-k8s.io/v1beta2
kind: ResourceFlavor
metadata:
  name: smoke-flavor
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: ClusterQueue
metadata:
  name: smoke-cq
spec:
  namespaceSelector: {}
  resourceGroups:
  - coveredResources: ["cpu", "memory"]
    flavors:
    - name: smoke-flavor
      resources:
      - name: cpu
        nominalQuota: "2"
      - name: memory
        nominalQuota: "2Gi"
---
apiVersion: kueue.x-k8s.io/v1beta2
kind: LocalQueue
metadata:
  name: smoke-lq
  namespace: ${SMOKE_NS}
spec:
  clusterQueue: smoke-cq
EOF

echo "Waiting for LocalQueue to be active..."
oc wait --for=condition=Active localqueue/smoke-lq -n "${SMOKE_NS}" --timeout=5m \
  || {
    echo "LocalQueue not Active. Debugging..."
    oc get localqueue smoke-lq -n "${SMOKE_NS}" -o yaml 2>/dev/null || true
    oc get clusterqueue smoke-cq -o yaml 2>/dev/null || true
    oc logs deployment/kueue-controller-manager -n "${NAMESPACE}" --tail=50 2>/dev/null || true
    exit 1
  }

echo "Creating smoke test job..."
oc apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: smoke-job
  namespace: ${SMOKE_NS}
  labels:
    kueue.x-k8s.io/queue-name: smoke-lq
spec:
  template:
    spec:
      containers:
      - name: test
        image: registry.access.redhat.com/ubi9/ubi-minimal:latest
        command: ["echo", "smoke-test-passed"]
        resources:
          requests:
            cpu: "100m"
            memory: "64Mi"
      restartPolicy: Never
  backoffLimit: 0
EOF

echo "Waiting for Kueue to create and admit the workload..."
for i in $(seq 1 30); do
  WL_NAME=$(oc get workload.kueue.x-k8s.io -n "${SMOKE_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${WL_NAME}" ]]; then
    echo "Workload found: ${WL_NAME}"
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    echo "ERROR: Workload not created after 5 minutes"
    exit 1
  fi
  sleep 10
done

oc wait --for=condition=Admitted "workload.kueue.x-k8s.io/${WL_NAME}" \
  -n "${SMOKE_NS}" --timeout=60s

echo "Waiting for job to complete..."
oc wait --for=condition=Complete job/smoke-job -n "${SMOKE_NS}" --timeout=2m

echo "Verifying workload finished..."
oc wait --for=condition=Finished "workload.kueue.x-k8s.io/${WL_NAME}" \
  -n "${SMOKE_NS}" --timeout=60s

echo "Smoke test passed — workload was admitted and completed through Kueue."
