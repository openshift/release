#!/bin/bash

set -euo pipefail

NAMESPACE=$(cat "${SHARED_DIR}/ephemeral-namespace")

diagnostics() {
    echo "--- Diagnostics ---"
    oc get pods -n "${NAMESPACE}" -l app=osci-workflow-validation -o wide 2>/dev/null || true
    oc describe pods -n "${NAMESPACE}" -l app=osci-workflow-validation 2>/dev/null || true
    oc get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null | tail -30 || true
    oc logs -n "${NAMESPACE}" -l app=osci-workflow-validation --tail=50 2>/dev/null || true
    echo "--- End Diagnostics ---"
}

trap 'diagnostics; echo "ERROR: osci-workflow-validation-smoke step failed" >&2' ERR

echo "Deploying osci-workflow-validation into namespace ${NAMESPACE}..."
echo "Image: ${OSCI_WORKFLOW_VALIDATION_IMAGE}"

# ---------------------------------------------------------------------------
# Create an image-pull secret so the ephemeral cluster can pull the CI image
# ---------------------------------------------------------------------------
echo "Generating CI registry pull credentials..."
KUBECONFIG="" oc registry login --to=/tmp/ci-pull-creds.json 2>/dev/null

export KUBECONFIG="${SHARED_DIR}/ephemeral-kubeconfig"
oc project "${NAMESPACE}"

oc create secret docker-registry ci-pull-secret \
    --from-file=.dockerconfigjson=/tmp/ci-pull-creds.json \
    --namespace="${NAMESPACE}" 2>/dev/null || \
    oc set data secret/ci-pull-secret \
    --from-file=.dockerconfigjson=/tmp/ci-pull-creds.json \
    --namespace="${NAMESPACE}"
rm -f /tmp/ci-pull-creds.json

cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: osci-workflow-validation
  namespace: ${NAMESPACE}
  labels:
    app: osci-workflow-validation
spec:
  replicas: 1
  selector:
    matchLabels:
      app: osci-workflow-validation
  template:
    metadata:
      labels:
        app: osci-workflow-validation
    spec:
      imagePullSecrets:
      - name: ci-pull-secret
      containers:
      - name: server
        image: ${OSCI_WORKFLOW_VALIDATION_IMAGE}
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: osci-workflow-validation
  namespace: ${NAMESPACE}
  labels:
    app: osci-workflow-validation
spec:
  selector:
    app: osci-workflow-validation
  ports:
  - port: 8080
    targetPort: 8080
    protocol: TCP
EOF

echo "Waiting up to ${DEPLOY_TIMEOUT}s for deployment to become ready..."
oc rollout status deployment/osci-workflow-validation \
    --namespace="${NAMESPACE}" \
    --timeout="${DEPLOY_TIMEOUT}s"

echo "Deployment is ready. Verifying /healthz endpoint..."

POD=$(oc get pods -n "${NAMESPACE}" -l app=osci-workflow-validation \
    -o jsonpath='{.items[0].metadata.name}')

HEALTH_RESPONSE=$(oc exec -n "${NAMESPACE}" "${POD}" -- \
    curl -sf http://localhost:8080/healthz 2>/dev/null || true)

if [[ "${HEALTH_RESPONSE}" == *'"status":"ok"'* ]]; then
    echo "Health check passed: ${HEALTH_RESPONSE}"
else
    echo "ERROR: Health check failed. Response: ${HEALTH_RESPONSE}" >&2
    echo "Pod logs:"
    oc logs -n "${NAMESPACE}" "${POD}" || true
    exit 1
fi

echo "Smoke test passed."
