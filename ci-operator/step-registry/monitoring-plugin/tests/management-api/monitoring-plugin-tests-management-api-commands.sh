#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# Run the plugin backend directly in this step container (which has the Go
# source and toolchain via from: src). The backend only needs kube API access
# to manage PrometheusRule CRDs — it does not need the full console plugin
# stack. KUBECONFIG is injected by ci-operator from the provisioned cluster.

PORT=9001

unset GOFLAGS
export GOCACHE=/tmp/go-build
export GOMODCACHE=/tmp/go-mod

echo "Building monitoring-plugin backend..."
go build -o /tmp/plugin-backend ./cmd/plugin-backend.go

echo "Starting monitoring-plugin backend on port ${PORT}..."
/tmp/plugin-backend \
  -port="${PORT}" \
  -config-path="./config" \
  -static-path="./web/dist" &
BACKEND_PID=$!
trap 'kill ${BACKEND_PID} 2>/dev/null || true' EXIT

echo "Waiting for backend to be ready..."
ready=false
for i in $(seq 1 30); do
  if curl -sf "http://localhost:${PORT}/health" > /dev/null 2>&1; then
    echo "Backend is ready"
    ready=true
    break
  fi
  echo "  attempt ${i}/30..."
  sleep 2
done

if [ "${ready}" != "true" ]; then
  echo "ERROR: Backend did not become ready after 30 attempts"
  exit 1
fi

echo "Running management API e2e tests..."
export PLUGIN_URL="http://localhost:${PORT}"

make test-e2e
