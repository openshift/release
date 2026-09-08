#!/bin/bash

set -o nounset
set -o pipefail

# Deploy Jaeger all-in-one as an in-cluster OTLP trace sink for Quay. Quay
# (in-cluster) exports OTLP HTTP to the jaeger Service on 4318; the post-run
# gather step reads collected traces from the query API on 16686.
#
# Best-effort: if Jaeger does not come up, log diagnostics, warn, and exit 0 so
# the e2e run continues without traces. No credentials are handled here.

ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

QUAY_NS="${QUAYNAMESPACE:-quay-enterprise}"
JAEGER_IMAGE="${JAEGER_IMAGE:-quay.io/jaegertracing/jaeger:2.20.0}"
JAEGER_MAX_TRACES="${JAEGER_MAX_TRACES:-50000}"
SHARED_DIR="${SHARED_DIR:-/tmp/shared}"

# Any failure in setup/apply/rollout is best-effort: warn, print diagnostics,
# leave ${SHARED_DIR}/jaeger_deployed unwritten, and exit 0.
fail() {
  echo "WARNING: $1; the run continues without traces." >&2
  oc get pods -n "${QUAY_NS}" -l app=jaeger -o wide || true
  oc describe deployment/jaeger -n "${QUAY_NS}" || true
  oc logs deploy/jaeger -n "${QUAY_NS}" --tail=100 || true
  exit 0
}

# Ensure the namespace exists (deploy-aws-s3 also creates it; be order-independent).
if ! oc get namespace "${QUAY_NS}" >/dev/null 2>&1 && ! oc create namespace "${QUAY_NS}"; then
  fail "could not ensure namespace ${QUAY_NS}"
fi

echo "Deploying Jaeger (${JAEGER_IMAGE}) into ${QUAY_NS}..."
# Jaeger 2.x is config-file driven (OpenTelemetry Collector based). The ConfigMap
# below is the trimmed upstream cmd/jaeger/config.yaml: OTLP receiver (grpc 4317,
# http 4318), a single in-memory storage backend, jaeger_query (UI/API 16686) and
# healthcheckv2. Sampling, extra receivers, and telemetry are dropped.
if ! oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: jaeger-config
  namespace: ${QUAY_NS}
  labels:
    app: jaeger
data:
  config.yaml: |
    service:
      extensions: [jaeger_storage, jaeger_query, healthcheckv2]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [jaeger_storage_exporter]
    extensions:
      healthcheckv2:
        use_v2: true
        http:
      jaeger_query:
        storage:
          traces: memstore
      jaeger_storage:
        backends:
          memstore:
            memory:
              max_traces: ${JAEGER_MAX_TRACES}
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch:
    exporters:
      jaeger_storage_exporter:
        trace_storage: memstore
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: ${QUAY_NS}
  labels:
    app: jaeger
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jaeger
  template:
    metadata:
      labels:
        app: jaeger
    spec:
      containers:
      - name: jaeger
        image: ${JAEGER_IMAGE}
        imagePullPolicy: IfNotPresent
        args:
        - "--config"
        - "/etc/jaeger/config.yaml"
        ports:
        - name: otlp-http
          containerPort: 4318
        - name: query
          containerPort: 16686
        readinessProbe:
          httpGet:
            path: /
            port: 16686
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            memory: 4Gi
        volumeMounts:
        - name: jaeger-config
          mountPath: /etc/jaeger
      volumes:
      - name: jaeger-config
        configMap:
          name: jaeger-config
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger
  namespace: ${QUAY_NS}
  labels:
    app: jaeger
spec:
  selector:
    app: jaeger
  ports:
  - name: otlp-http
    port: 4318
    targetPort: 4318
  - name: query
    port: 16686
    targetPort: 16686
EOF
then
  fail "oc apply failed"
fi

echo "Waiting for Jaeger rollout..."
if ! oc rollout status deployment/jaeger -n "${QUAY_NS}" --timeout=5m; then
  fail "Jaeger did not roll out"
fi

# Record the deploy time (epoch seconds) so the gather step can bound its trace
# export to windows starting here instead of exporting the whole store at once.
date +%s > "${SHARED_DIR}/jaeger_deployed"
cp "${SHARED_DIR}/jaeger_deployed" "${ARTIFACT_DIR}/jaeger_deployed" || true
echo "Jaeger ready. In-cluster OTLP endpoint: http://jaeger.${QUAY_NS}.svc.cluster.local:4318/v1/traces"

exit 0
