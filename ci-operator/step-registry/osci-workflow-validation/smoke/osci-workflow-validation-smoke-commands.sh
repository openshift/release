#!/bin/bash

set -euo pipefail

trap 'echo "ERROR: osci-workflow-validation-smoke step failed" >&2' ERR

NAMESPACE=$(cat "${SHARED_DIR}/ephemeral-namespace")
export KUBECONFIG="${SHARED_DIR}/ephemeral-kubeconfig"

echo "Deploying osci-workflow-validation into namespace ${NAMESPACE}..."
echo "Image: ${OSCI_WORKFLOW_VALIDATION_IMAGE}"

oc project "${NAMESPACE}"

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
