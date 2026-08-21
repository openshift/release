#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Deploy Mailpit as an in-cluster SMTP sink + HTTP API for Quay mailing tests.
# Quay (in-cluster) sends SMTP to the mailpit Service on 1025; the Playwright pod
# (external) reads delivered mail over the HTTP API exposed via an edge Route.
# No credentials are handled here, so tracing (set -x) is safe to omit anyway.

ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

QUAY_NS="${QUAYNAMESPACE}"

# Ensure the namespace exists (deploy-aws-s3 also creates it; be order-independent).
oc get namespace "${QUAY_NS}" >/dev/null 2>&1 || oc create namespace "${QUAY_NS}"

echo "Deploying Mailpit (${MAILPIT_IMAGE}) into ${QUAY_NS}..."
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mailpit
  namespace: ${QUAY_NS}
  labels:
    app: mailpit
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mailpit
  template:
    metadata:
      labels:
        app: mailpit
    spec:
      containers:
      - name: mailpit
        image: ${MAILPIT_IMAGE}
        imagePullPolicy: IfNotPresent
        ports:
        - name: smtp
          containerPort: 1025
        - name: http
          containerPort: 8025
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8025
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: mailpit
  namespace: ${QUAY_NS}
  labels:
    app: mailpit
spec:
  selector:
    app: mailpit
  ports:
  - name: smtp
    port: 1025
    targetPort: 1025
  - name: http
    port: 8025
    targetPort: 8025
EOF

echo "Waiting for Mailpit rollout..."
oc rollout status deployment/mailpit -n "${QUAY_NS}" --timeout=5m

# Expose the HTTP API via an edge-terminated route. The Playwright pod trusts it
# because the test step sets NODE_TLS_REJECT_UNAUTHORIZED=0 for the run.
oc create route edge mailpit --service=mailpit --port=http -n "${QUAY_NS}" \
  --insecure-policy=Redirect --dry-run=client -o yaml | oc apply -f -

MAILPIT_HOST=""
for _ in $(seq 1 30); do
  MAILPIT_HOST=$(oc get route mailpit -n "${QUAY_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  [[ -n "${MAILPIT_HOST}" ]] && break
  sleep 5
done
if [[ -z "${MAILPIT_HOST}" ]]; then
  echo "ERROR: Mailpit route host not available" >&2
  oc get route mailpit -n "${QUAY_NS}" -o yaml >&2 || true
  exit 1
fi

# utils/mailpit.ts calls `${MAILPIT_API}/messages`; Mailpit serves that under
# /api/v1, so the base URL includes the /api/v1 segment.
MAILPIT_API="https://${MAILPIT_HOST}/api/v1"
echo "${MAILPIT_API}" > "${SHARED_DIR}/mailpit_api"
cp "${SHARED_DIR}/mailpit_api" "${ARTIFACT_DIR}/mailpit_api" || true
echo "Mailpit API: ${MAILPIT_API}"
