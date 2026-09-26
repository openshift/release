#!/bin/bash
set -o nounset
set -o pipefail
set -x

# Source proxy config
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  set +x
  source "${SHARED_DIR}/proxy-conf.sh"
  set -x
fi

pushd /tmp || exit

ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")

# Clone e2e-benchmarking (same as original step)
REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking"
LATEST_TAG=$(git ls-remote --tags https://github.com/cloud-bulldozer/e2e-benchmarking.git | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "${E2E_VERSION:-default}" == "default" ]; then echo "$LATEST_TAG"; else echo "${E2E_VERSION}"; fi)"
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/ingress-perf || exit

# ES Configuration (same as original step)
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
export ES_INDEX="ingress-performance"

# Run the full ingress-perf test suite (same as production)
echo "========================================"
echo "=== Running ingress-perf (same as production data-path test) ==="
echo "========================================"
./run.sh
INGRESS_PERF_EXIT=$?
echo "=== ingress-perf exit code: $INGRESS_PERF_EXIT ==="

popd || exit  # back to /tmp

# === DEBUG: Capture the exact hloader error ===
echo ""
echo "========================================"
echo "=== DEBUG: Running hloader directly to capture error ==="
echo "========================================"

# Download hloader v0.2.1 (same version bundled in ingress-perf container)
ARCH=$(arch | sed s/aarch64/arm64/)
curl -sS -L "https://github.com/rsevilla87/hloader/releases/download/v0.2.1/hloader-Linux-v0.2.1-${ARCH}.tar.gz" | tar xz -C /tmp/

# Set up a fresh passthrough route for direct testing
DEBUG_NS="ingress-perf-debug"
oc create ns $DEBUG_NS || true

# Deploy nginx server (same image as ingress-perf uses)
cat <<'EOF' | oc apply -n $DEBUG_NS -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-server
  template:
    metadata:
      labels:
        app: nginx-server
    spec:
      containers:
      - name: nginx
        image: quay.io/cloud-bulldozer/nginx:latest
        ports:
        - containerPort: 8443
          name: https
        - containerPort: 8080
          name: http
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-server
spec:
  selector:
    app: nginx-server
  ports:
  - name: https
    port: 8443
    targetPort: 8443
  - name: http
    port: 8080
    targetPort: 8080
EOF

oc rollout status deployment/nginx-server -n $DEBUG_NS --timeout=120s

# Create passthrough route
oc create route passthrough nginx-passthrough --service=nginx-server --port=8443 -n $DEBUG_NS
sleep 15  # Wait for route admission
ROUTE_HOST=$(oc get route nginx-passthrough -n $DEBUG_NS -o jsonpath='{.spec.host}')
echo "Passthrough route host: $ROUTE_HOST"

echo ""
echo "=== Sanity: HTTP/1.1 passthrough (10 connections, 15s) ==="
/tmp/hloader -u "https://${ROUTE_HOST}/1024.html" -c 10 -d 15s --http2=false --keepalive=true -r 0 -t 10s 2>&1 || true

echo ""
echo "=== REPRODUCER: HTTP/2 passthrough (200 connections, 3m — same as failing test 7) ==="
echo "Command: hloader -u https://${ROUTE_HOST}/1024.html -c 200 -d 3m --http2=true --keepalive=true -r 0 -t 10s"
/tmp/hloader -u "https://${ROUTE_HOST}/1024.html" -c 200 -d 3m --http2=true --keepalive=true -r 0 -t 10s 2>&1
HLOADER_EXIT=$?
echo ""
echo "=== hloader direct exit code: $HLOADER_EXIT ==="

# Capture router diagnostics
echo ""
echo "=== Router pod info ==="
oc get pods -n openshift-ingress -o wide 2>/dev/null || true
echo ""
echo "=== HAProxy version ==="
ROUTER_POD=$(oc get pods -n openshift-ingress -l ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$ROUTER_POD" ]; then
  oc exec -n openshift-ingress "$ROUTER_POD" -c haproxy -- haproxy -v 2>/dev/null || \
  oc exec -n openshift-ingress "$ROUTER_POD" -c router -- haproxy -v 2>/dev/null || true
  echo ""
  echo "=== Router container resources ==="
  oc get pod "$ROUTER_POD" -n openshift-ingress -o jsonpath='{range .spec.containers[*]}{.name}: cpu={.resources.requests.cpu} mem={.resources.requests.memory}{"\n"}{end}' 2>/dev/null || true
fi

# Cleanup
oc delete ns $DEBUG_NS --wait=false 2>/dev/null || true

# Exit with the original ingress-perf exit code
exit $INGRESS_PERF_EXIT
