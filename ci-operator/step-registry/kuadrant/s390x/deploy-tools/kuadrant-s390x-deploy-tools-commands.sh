#!/bin/bash

set -euo pipefail

TOOLS_NS="${TOOLS_NAMESPACE}"
KEYCLOAK_URL_FILE="${SHARED_DIR}/keycloak-url"
MOCKSERVER_URL_FILE="${SHARED_DIR}/mockserver-url"
JAEGER_QUERY_URL_FILE="${SHARED_DIR}/jaeger-query-url"

echo "=== Deploying testing tools into namespace ${TOOLS_NS} ==="
oc get ns "${TOOLS_NS}" >/dev/null 2>&1 || oc create ns "${TOOLS_NS}"

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

echo "--- Mockserver ---"
cat <<EOF | oc apply -n "${TOOLS_NS}" -f -
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
