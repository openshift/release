#!/bin/bash
set -euo pipefail

NAMESPACE="sippy-staging"
POSTGRES_PASSWORD="sippy-staging-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"

echo "==> Creating namespace ${NAMESPACE}"
oc new-project "${NAMESPACE}" || oc project "${NAMESPACE}"

echo "==> Creating image pull secret"
oc create secret generic pull-secret \
  --from-file=.dockerconfigjson="${DOCKERCONFIGJSON}" \
  --type=kubernetes.io/dockerconfigjson \
  -n "${NAMESPACE}"

echo "==> Creating GCS credentials secret"
oc create secret generic gcs-sa \
  --from-file=gcs-sa="${GCS_SA_JSON_PATH}" \
  -n "${NAMESPACE}"

echo "==> Deploying PostgreSQL"
oc apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: quay.io/sclorg/postgresql-16-c9s:latest
        env:
        - name: POSTGRESQL_USER
          value: sippy
        - name: POSTGRESQL_PASSWORD
          value: "${POSTGRES_PASSWORD}"
        - name: POSTGRESQL_DATABASE
          value: sippy
        ports:
        - containerPort: 5432
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            memory: 2Gi
        readinessProbe:
          tcpSocket:
            port: 5432
          initialDelaySeconds: 10
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
    targetPort: 5432
EOF

echo "==> Waiting for PostgreSQL to be ready"
oc wait --for=condition=Available deployment/postgres -n "${NAMESPACE}" --timeout=180s
oc wait --for=condition=Ready pod -l app=postgres -n "${NAMESPACE}" --timeout=180s

SIPPY_DATABASE_DSN="postgresql://sippy:${POSTGRES_PASSWORD}@postgres.${NAMESPACE}.svc:5432/sippy?sslmode=disable"

echo "==> Deploying sippy staging environment"
oc apply -n "${NAMESPACE}" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sippy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sippy
  template:
    metadata:
      labels:
        app: sippy
    spec:
      imagePullSecrets:
      - name: pull-secret
      containers:
      - name: sippy
        image: "${STAGING_IMAGE}"
        command:
        - /bin/bash
        - -c
        - |
          set -euo pipefail
          echo "==> Loading data into database..."
          /workspace/bin/sippy load \
            --database-dsn "\${SIPPY_DATABASE_DSN}" \
            --google-service-account-credential-file /var/run/gcs-sa/gcs-sa \
            --mode ocp
          echo "==> Starting sippy server..."
          exec /workspace/bin/sippy serve \
            --listen-addr 0.0.0.0:8080 \
            --database-dsn "\${SIPPY_DATABASE_DSN}"
        env:
        - name: SIPPY_DATABASE_DSN
          value: "${SIPPY_DATABASE_DSN}"
        ports:
        - containerPort: 8080
          name: http
        volumeMounts:
        - name: gcs-sa
          mountPath: /var/run/gcs-sa
          readOnly: true
        resources:
          requests:
            cpu: 500m
            memory: 2Gi
          limits:
            memory: 4Gi
        readinessProbe:
          httpGet:
            path: /api/health
            port: 8080
          initialDelaySeconds: 120
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 30
      volumes:
      - name: gcs-sa
        secret:
          secretName: gcs-sa
---
apiVersion: v1
kind: Service
metadata:
  name: sippy
spec:
  selector:
    app: sippy
  ports:
  - port: 8080
    targetPort: 8080
    name: http
EOF

echo "==> Creating HTTPS route"
oc create route edge sippy --service=sippy --port=http -n "${NAMESPACE}"

SIPPY_URL="https://$(oc get route sippy -n "${NAMESPACE}" -o jsonpath='{.spec.host}')"

echo "==> Waiting for sippy to be ready (this may take several minutes while data loads)..."
oc wait --for=condition=Available deployment/sippy -n "${NAMESPACE}" --timeout=600s || true

echo ""
echo "============================================================"
echo "  Sippy Staging Environment"
echo "============================================================"
echo ""
echo "  URL: ${SIPPY_URL}"
echo ""
echo "  The environment will remain available until the wait step"
echo "  times out (check the next step for the countdown)."
echo ""
echo "============================================================"
echo ""

oc get pods -n "${NAMESPACE}"
