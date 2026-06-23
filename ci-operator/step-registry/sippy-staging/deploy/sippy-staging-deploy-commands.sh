#!/bin/bash
set -euo pipefail

NAMESPACE="sippy-staging"

echo "==> Creating namespace ${NAMESPACE}"
oc new-project "${NAMESPACE}" || oc project "${NAMESPACE}"

echo "==> Creating image pull secret"
oc create secret generic pull-secret \
  --from-file=.dockerconfigjson="${DOCKERCONFIGJSON}" \
  --type=kubernetes.io/dockerconfigjson \
  -n "${NAMESPACE}"

echo "==> Deploying PostgreSQL and Redis"
oc apply -n "${NAMESPACE}" -f - <<'EOF'
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
        image: quay.io/enterprisedb/postgresql:latest
        env:
        - name: POSTGRES_PASSWORD
          value: password
        - name: POSTGRES_HOST_AUTH_METHOD
          value: trust
        args: ["-c", "listen_addresses=*"]
        ports:
        - containerPort: 5432
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            memory: 2Gi
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "postgres"]
          initialDelaySeconds: 5
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
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: docker.io/redis:7-alpine
        args: ["--maxmemory", "4gb", "--maxmemory-policy", "allkeys-lru"]
        ports:
        - containerPort: 6379
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 4Gi
        readinessProbe:
          exec:
            command: ["redis-cli", "ping"]
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
EOF

echo "==> Waiting for PostgreSQL and Redis to be ready"
oc wait --for=condition=Available deployment/postgres -n "${NAMESPACE}" --timeout=180s
oc wait --for=condition=Available deployment/redis -n "${NAMESPACE}" --timeout=180s

echo "==> Deploying sippy devcontainer"
oc apply -n "${NAMESPACE}" -f - <<OUTER
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
          DSN="postgresql://postgres:password@postgres.${NAMESPACE}.svc:5432/postgres?sslmode=disable"

          echo "==> Seeding database..."
          /workspace/bin/sippy seed-data --init-database --database-dsn="\${DSN}"

          echo "==> Starting sippy server..."
          exec /workspace/bin/sippy serve \\
            --listen ":8080" \\
            --listen-metrics ":2112" \\
            --database-dsn="\${DSN}" \\
            --data-provider postgres \\
            --views /workspace/config/seed-views.yaml \\
            --redis-url="redis://redis.${NAMESPACE}.svc:6379" \\
            --enable-write-endpoints
        ports:
        - containerPort: 8080
          name: http
        resources:
          requests:
            cpu: "1"
            memory: 4Gi
          limits:
            memory: 8Gi
        readinessProbe:
          httpGet:
            path: /api/health
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 30
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
OUTER

echo "==> Creating HTTPS route"
oc create route edge sippy --service=sippy --port=http -n "${NAMESPACE}"

SIPPY_URL="https://$(oc get route sippy -n "${NAMESPACE}" -o jsonpath='{.spec.host}')"

echo "==> Waiting for sippy to be ready (seeding may take a few minutes)..."
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
