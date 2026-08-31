#!/bin/bash

set -euo pipefail

TOOLS_NS="${TOOLS_NAMESPACE}"
KEYCLOAK_URL_FILE="${SHARED_DIR}/keycloak-url"
MOCKSERVER_URL_FILE="${SHARED_DIR}/mockserver-url"
JAEGER_QUERY_URL_FILE="${SHARED_DIR}/jaeger-query-url"
PROMETHEUS_URL_FILE="${SHARED_DIR}/prometheus-url"

echo "=== Deploying testing tools into namespace ${TOOLS_NS} ==="
oc get ns "${TOOLS_NS}" >/dev/null 2>&1 || oc create ns "${TOOLS_NS}"

# ---------------------------------------------------------------------------
# Egress tests read openshift-ingress/custom-cert for TLS origination CA
# (testsuite/tests/singlecluster/egress/conftest.py ingress_ca_secret).
# OCP provides router-certs-default; the testsuite expects custom-cert.
# ---------------------------------------------------------------------------
echo "=== openshift-ingress custom-cert (egress TLS origination) ==="
if ! oc get secret custom-cert -n openshift-ingress >/dev/null 2>&1; then
  oc get secret router-certs-default -n openshift-ingress -o yaml \
    | sed 's/name: router-certs-default/name: custom-cert/' \
    | oc apply -f -
  echo "Created custom-cert from router-certs-default"
else
  echo "custom-cert already exists"
fi

# ---------------------------------------------------------------------------
# OpenShift cluster monitoring (same approach as rhcl-mc1): do NOT install a
# separate Prometheus. Enable User Workload Monitoring so ServiceMonitors are
# scraped, then point the testsuite at thanos-querier (openshift-monitoring).
# ---------------------------------------------------------------------------
echo "--- Enable OpenShift user workload monitoring ---"
MONITORING_NS="openshift-monitoring"
MONITORING_CM="cluster-monitoring-config"
CURRENT_CFG="$(oc -n "${MONITORING_NS}" get cm "${MONITORING_CM}" \
  -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)"
if [[ -z "${CURRENT_CFG}" ]]; then
  NEW_CFG=$'enableUserWorkload: true\n'
elif echo "${CURRENT_CFG}" | grep -qE '^[[:space:]]*enableUserWorkload:'; then
  NEW_CFG="$(printf '%s\n' "${CURRENT_CFG}" | sed -E 's/^([[:space:]]*enableUserWorkload:).*/\1 true/')"
else
  NEW_CFG="${CURRENT_CFG}"$'\n'$'enableUserWorkload: true\n'
fi
oc -n "${MONITORING_NS}" create configmap "${MONITORING_CM}" \
  --from-literal=config.yaml="${NEW_CFG}" \
  --dry-run=client -o yaml | oc apply -f -
echo "cluster-monitoring-config:"
oc -n "${MONITORING_NS}" get cm "${MONITORING_CM}" -o jsonpath='{.data.config\.yaml}'
echo

echo "--- Waiting for user-workload Prometheus ---"
# Namespace + operands appear after the platform operator reconciles UWM.
for _ in $(seq 1 60); do
  if oc get ns openshift-user-workload-monitoring >/dev/null 2>&1 \
    && oc -n openshift-user-workload-monitoring get prometheus prometheus-user-workload >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
oc -n openshift-user-workload-monitoring rollout status \
  statefulset/prometheus-user-workload --timeout=300s || true
oc -n openshift-user-workload-monitoring wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=prometheus --timeout=300s || true

# Prefer in-cluster thanos-querier for the testsuite Job (runs on-cluster).
# HTTPS + bearer token matches the testsuite Prometheus fixture (verify=False).
PROMETHEUS_URL="https://thanos-querier.${MONITORING_NS}.svc.cluster.local:9091"
THANOS_ROUTE_HOST="$(oc -n "${MONITORING_NS}" get route thanos-querier \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -n "${THANOS_ROUTE_HOST}" ]]; then
  echo "thanos-querier route: https://${THANOS_ROUTE_HOST}"
fi
echo "${PROMETHEUS_URL}" > "${PROMETHEUS_URL_FILE}"
echo "Prometheus (thanos-querier) URL for testsuite: ${PROMETHEUS_URL}"

echo "--- Keycloak ---"
# Disable tracing around password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
cat <<EOF | oc apply -n "${TOOLS_NS}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  labels:
    app: keycloak
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
      - name: keycloak
        image: ${KEYCLOAK_IMAGE}
        args: ["start-dev"]
        env:
        # Keycloak 26+ / Red Hat build of Keycloak bootstrap admin variables
        - name: KC_BOOTSTRAP_ADMIN_USERNAME
          value: "${KEYCLOAK_ADMIN_USERNAME}"
        - name: KC_BOOTSTRAP_ADMIN_PASSWORD
          value: "${KEYCLOAK_ADMIN_PASSWORD}"
        # Legacy variables (pre-26) kept for backward compatibility
        - name: KEYCLOAK_ADMIN
          value: "${KEYCLOAK_ADMIN_USERNAME}"
        - name: KEYCLOAK_ADMIN_PASSWORD
          value: "${KEYCLOAK_ADMIN_PASSWORD}"
        ports:
        - containerPort: 8080
          name: http
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  labels:
    app: keycloak
spec:
  selector:
    app: keycloak
  ports:
  - name: http
    port: 8080
    targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: keycloak
  labels:
    app: keycloak
spec:
  to:
    kind: Service
    name: keycloak
  port:
    targetPort: http
EOF
$WAS_TRACING && set -x

echo "--- Mockserver (with echo expectation for testsuite) ---"
# Phase 1 egress hits GET /get. MockServer treats path /.* as an exact string,
# not a regex, so the catch-all never matches /get (404). Explicit /get is required.
# CI points mockserver.url at this tools Route, so Phase 1 uses this ConfigMap.
cat <<EOF | oc apply -n "${TOOLS_NS}" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: mockserver-config
  labels:
    app: mockserver
data:
  echo_expectation.json: |
    [
      {
        "id": "get",
        "priority": 100,
        "httpRequest": {
          "path": "/get"
        },
        "httpResponse": {
          "statusCode": 200,
          "body": "OK"
        }
      },
      {
        "id": "echo",
        "priority": -10,
        "httpRequest": {
          "path": "/.*"
        },
        "httpResponse": {
          "statusCode": 200,
          "headers": {
            "content-type": ["application/json"]
          },
          "body": {
            "method": "\${json-unit.any-string}",
            "path": "\${json-unit.any-string}",
            "headers": {},
            "body": ""
          }
        }
      }
    ]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mockserver
  labels:
    app: mockserver
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mockserver
  template:
    metadata:
      labels:
        app: mockserver
    spec:
      containers:
      - name: mockserver
        image: ${MOCKSERVER_IMAGE}
        ports:
        - containerPort: 1080
          name: http
        env:
        - name: MOCKSERVER_INITIALIZATION_JSON_PATH
          value: /config/mockserver/echo_expectation.json
        volumeMounts:
        - name: mockserver-config
          mountPath: /config/mockserver
          readOnly: true
      volumes:
      - name: mockserver-config
        configMap:
          name: mockserver-config
---
apiVersion: v1
kind: Service
metadata:
  name: mockserver
  labels:
    app: mockserver
spec:
  selector:
    app: mockserver
  ports:
  - name: http
    port: 1080
    targetPort: 1080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: mockserver
  labels:
    app: mockserver
spec:
  to:
    kind: Service
    name: mockserver
  port:
    targetPort: http
EOF

echo "--- Jaeger (all-in-one) ---"
cat <<EOF | oc apply -n "${TOOLS_NS}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
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
        env:
        - name: COLLECTOR_OTLP_ENABLED
          value: "true"
        ports:
        - containerPort: 16686
          name: query
        - containerPort: 4317
          name: otlp-grpc
        - containerPort: 4318
          name: otlp-http
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger-query
  labels:
    app: jaeger
spec:
  selector:
    app: jaeger
  ports:
  - name: http
    port: 80
    targetPort: 16686
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger-collector
  labels:
    app: jaeger
spec:
  selector:
    app: jaeger
  ports:
  - name: otlp-grpc
    port: 4317
    targetPort: 4317
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: jaeger-query
  labels:
    app: jaeger
spec:
  to:
    kind: Service
    name: jaeger-query
  port:
    targetPort: http
EOF

echo "=== Waiting for tool deployments to become Available ==="
oc wait --for=condition=Available deployment/keycloak -n "${TOOLS_NS}" --timeout=300s
oc wait --for=condition=Available deployment/mockserver -n "${TOOLS_NS}" --timeout=300s
oc wait --for=condition=Available deployment/jaeger -n "${TOOLS_NS}" --timeout=300s

KEYCLOAK_URL="http://$(oc get route keycloak -n "${TOOLS_NS}" -o jsonpath='{.spec.host}')"
MOCKSERVER_URL="http://$(oc get route mockserver -n "${TOOLS_NS}" -o jsonpath='{.spec.host}')"
JAEGER_QUERY_URL="http://$(oc get route jaeger-query -n "${TOOLS_NS}" -o jsonpath='{.spec.host}')"

echo "${KEYCLOAK_URL}" > "${KEYCLOAK_URL_FILE}"
echo "${MOCKSERVER_URL}" > "${MOCKSERVER_URL_FILE}"
echo "${JAEGER_QUERY_URL}" > "${JAEGER_QUERY_URL_FILE}"

echo "=== Testing tools deployed ==="
echo "Keycloak URL:    ${KEYCLOAK_URL}"
echo "Mockserver URL:  ${MOCKSERVER_URL}"
echo "Jaeger query:    ${JAEGER_QUERY_URL}"
echo "Jaeger collector: rpc://jaeger-collector.${TOOLS_NS}.svc.cluster.local:4317"
echo "Prometheus URL:  $(cat "${PROMETHEUS_URL_FILE}")"

# ---------------------------------------------------------------------------
# Enable Kuadrant observability + control-plane OTEL (rhcl-mc1 pattern).
# Must run AFTER Jaeger is Available so the collector endpoint resolves.
# - Kuadrant CR.spec.observability.enable → ServiceMonitors / dataplane tracing
# - Subscription OTEL_* env → control-plane tracing tests (OTEL_* on manager)
# ---------------------------------------------------------------------------
KUADRANT_NS="${KUADRANT_NAMESPACE:-kuadrant-system}"
KUADRANT_SUB="${KUADRANT_SUBSCRIPTION_NAME:-rhcl-operator}"
JAEGER_COLLECTOR_ENDPOINT="rpc://jaeger-collector.${TOOLS_NS}.svc.cluster.local:4317"
# OTLP HTTP for operator logs/metrics; gRPC (rpc://) for traces — matches examples/otel.
OTEL_HTTP_ENDPOINT="http://jaeger-collector.${TOOLS_NS}.svc.cluster.local:4318"

if oc get kuadrant/kuadrant -n "${KUADRANT_NS}" >/dev/null 2>&1; then
  echo "=== Enabling Kuadrant CR observability (rhcl-mc1 pattern) ==="
  oc patch kuadrant/kuadrant -n "${KUADRANT_NS}" --type merge -p "{
    \"spec\": {
      \"observability\": {
        \"enable\": true,
        \"tracing\": {
          \"defaultEndpoint\": \"${JAEGER_COLLECTOR_ENDPOINT}\",
          \"insecure\": true
        }
      }
    }
  }"
  oc get kuadrant/kuadrant -n "${KUADRANT_NS}" -o jsonpath='{.spec.observability}' ; echo
else
  echo "WARNING: kuadrant/kuadrant not found in ${KUADRANT_NS}; skipping observability patch" >&2
fi

if oc get subscription "${KUADRANT_SUB}" -n "${KUADRANT_NS}" >/dev/null 2>&1; then
  echo "=== Setting OTEL_* on Kuadrant Subscription (control-plane tracing) ==="
  # Merge OTEL env into existing Subscription.config.env (preserve RELATED_IMAGE_WASMSHIM etc.).
  oc get subscription "${KUADRANT_SUB}" -n "${KUADRANT_NS}" -o json \
    | jq --arg http "${OTEL_HTTP_ENDPOINT}" --arg grpc_rpc "${JAEGER_COLLECTOR_ENDPOINT}" '
      .spec.config = (.spec.config // {})
      | .spec.config.env = (
          ((.spec.config.env // [])
            | map(select(.name | startswith("OTEL_") | not)))
          + [
              {"name":"OTEL_EXPORTER_OTLP_ENDPOINT","value":$http},
              {"name":"OTEL_EXPORTER_OTLP_INSECURE","value":"true"},
              {"name":"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT","value":$grpc_rpc},
              {"name":"OTEL_SERVICE_NAME","value":"kuadrant-operator"}
            ]
        )
      ' \
    | oc apply -f -
  oc rollout status deployment/kuadrant-operator-controller-manager \
    -n "${KUADRANT_NS}" --timeout=300s || true
  echo "Operator OTEL env:"
  oc set env deployment/kuadrant-operator-controller-manager -n "${KUADRANT_NS}" --list \
    | grep '^OTEL_' || echo "WARNING: no OTEL_* on deployment yet" >&2
else
  echo "WARNING: subscription ${KUADRANT_SUB} not found in ${KUADRANT_NS}; skipping OTEL env" >&2
fi

# ---------------------------------------------------------------------------
# Phase 2 egress: Authorino must trust the cluster CA so metadata.http can
# call https://kubernetes.default.svc (credential-injection-by-destination)
# and so Vault Kubernetes auth TokenReviews work. Volume name is required
# by testsuite/tests/singlecluster/egress/credentials_injection/conftest.py.
# ---------------------------------------------------------------------------
echo "=== Authorino cluster-trust-bundle (egress credential injection) ==="
if oc get authorino authorino -n "${KUADRANT_NS}" >/dev/null 2>&1; then
  AUTHORINO_POD="$(oc get pod -l authorino-resource=authorino -n "${KUADRANT_NS}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${AUTHORINO_POD}" ]]; then
    echo "WARNING: no Authorino pod found in ${KUADRANT_NS}; skipping cluster-trust-bundle" >&2
  else
    oc exec "${AUTHORINO_POD}" -n "${KUADRANT_NS}" -- sh -c \
      'cat /etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt /var/run/secrets/kubernetes.io/serviceaccount/ca.crt 2>/dev/null' \
      > /tmp/authorino-ca-bundle.crt || true
    if [[ ! -s /tmp/authorino-ca-bundle.crt ]]; then
      echo "WARNING: could not read CA bundle from ${AUTHORINO_POD}" >&2
    else
      # oc apply stores the full YAML in last-applied-configuration (256KiB
      # annotation limit). A RHEL ca-bundle duplicated as two keys overflowed
      # that on this cluster. create does not write that annotation.
      oc delete configmap authorino-cluster-trust-ca-bundle -n "${KUADRANT_NS}" --ignore-not-found
      oc create configmap authorino-cluster-trust-ca-bundle -n "${KUADRANT_NS}" \
        --from-file=ca-bundle.crt=/tmp/authorino-ca-bundle.crt \
        --from-file=ca-certificates.crt=/tmp/authorino-ca-bundle.crt
      oc patch authorino authorino -n "${KUADRANT_NS}" --type merge -p '{
        "spec": {
          "volumes": {
            "items": [
              {
                "name": "cluster-trust-bundle",
                "mountPath": "/etc/ssl/certs",
                "configMaps": ["authorino-cluster-trust-ca-bundle"]
              }
            ]
          }
        }
      }'
      oc wait --for=condition=Ready pod -l authorino-resource=authorino \
        -n "${KUADRANT_NS}" --timeout=180s || true
      echo "Authorino cluster-trust-bundle applied"
    fi
  fi
else
  echo "WARNING: authorino/authorino not found in ${KUADRANT_NS}; skipping cluster-trust-bundle" >&2
fi

# ---------------------------------------------------------------------------
# Phase 2 egress: Vault OSS in tools-vault (testsuite fetch_service_ip default).
# Dev mode, root token, KV v2 at secret/, Kubernetes auth for AuthPolicy login.
# Image must be s390x (hashicorp/vault has no s390x; use the OSS build).
# ---------------------------------------------------------------------------
VAULT_NS="${VAULT_NAMESPACE:-tools-vault}"
VAULT_IMAGE="${VAULT_IMAGE:-quay.io/mtahoor/vault-oss:1.21.2-s390x}"
VAULT_URL_FILE="${SHARED_DIR}/vault-url"

echo "=== Vault OSS (${VAULT_IMAGE}) in ${VAULT_NS} ==="
oc get ns "${VAULT_NS}" >/dev/null 2>&1 || oc create ns "${VAULT_NS}"
oc -n "${VAULT_NS}" create sa vault --dry-run=client -o yaml | oc apply -f -
oc adm policy add-scc-to-user anyuid -z vault -n "${VAULT_NS}"
oc create clusterrolebinding kuadrant-vault-auth-delegator \
  --clusterrole=system:auth-delegator \
  --serviceaccount="${VAULT_NS}:vault" \
  --dry-run=client -o yaml | oc apply -f -

cat <<EOF | oc apply -n "${VAULT_NS}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault
  labels:
    app: vault
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vault
  template:
    metadata:
      labels:
        app: vault
    spec:
      serviceAccountName: vault
      nodeSelector:
        kubernetes.io/arch: s390x
      containers:
      - name: vault
        image: ${VAULT_IMAGE}
        imagePullPolicy: Always
        args:
        - server
        - -dev
        - -dev-root-token-id=root
        - -dev-listen-address=0.0.0.0:8200
        - -dev-no-store-token
        env:
        - name: HOME
          value: /tmp
        - name: VAULT_DEV_ROOT_TOKEN_ID
          value: "root"
        - name: VAULT_DEV_LISTEN_ADDRESS
          value: "0.0.0.0:8200"
        ports:
        - containerPort: 8200
          name: http
        readinessProbe:
          httpGet:
            path: /v1/sys/health
            port: http
          initialDelaySeconds: 5
          periodSeconds: 5
          failureThreshold: 24
---
apiVersion: v1
kind: Service
metadata:
  name: vault
  labels:
    app: vault
spec:
  selector:
    app: vault
  ports:
  - name: http
    port: 8200
    targetPort: 8200
EOF

oc wait --for=condition=Available deployment/vault -n "${VAULT_NS}" --timeout=300s
oc wait --for=condition=Ready pod -l app=vault -n "${VAULT_NS}" --timeout=300s

echo "=== Enable Vault Kubernetes auth ==="
# disable_iss_validation: OCP SA tokens use issuer https://kubernetes.default.svc
oc exec -n "${VAULT_NS}" deploy/vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
  vault auth enable kubernetes || true
oc exec -n "${VAULT_NS}" deploy/vault -- sh -c '
  export VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root
  vault write auth/kubernetes/config \
    kubernetes_host="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
    token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token \
    disable_iss_validation=true
'
oc exec -n "${VAULT_NS}" deploy/vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault status || true

VAULT_URL="http://vault.${VAULT_NS}.svc.cluster.local:8200"
echo "${VAULT_URL}" > "${VAULT_URL_FILE}"
echo "Vault URL for testsuite (in-cluster): ${VAULT_URL}"
