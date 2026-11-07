#!/bin/bash

set -euo pipefail

dump_artifacts() {
  oc get datasciencecluster/default-dsc -o yaml > "${ARTIFACT_DIR}/dsc.yaml" || true
  oc get mcpserver/ocp-mcp-server -n ocp-mcp-server -o yaml > "${ARTIFACT_DIR}/mcpserver.yaml" || true
  oc get deployment/ocp-mcp-server -n ocp-mcp-server -o yaml > "${ARTIFACT_DIR}/deployment.yaml" || true
  oc logs deployment/ocp-mcp-server -n ocp-mcp-server --all-containers=true > "${ARTIFACT_DIR}/deployment.log" || true
  oc logs deployment/mcp-lifecycle-module-operator-controller-manager -n opendatahub --all-containers=true > "${ARTIFACT_DIR}/mcp-lifecycle-module-operator.log" || true
  oc logs deployment/mcp-lifecycle-operator-controller-manager -n opendatahub --all-containers=true > "${ARTIFACT_DIR}/mcp-lifecycle-operator.log" || true
}
trap dump_artifacts EXIT

wait_for_deployment() {
  local deployment=$1

  for attempt in $(seq 1 60); do
    if oc get "deployment/${deployment}" -n opendatahub >/dev/null 2>&1; then
      oc wait "deployment/${deployment}" -n opendatahub \
        --for=condition=Available --timeout=10m
      return
    fi
    echo "Waiting for deployment/${deployment} to be created (${attempt}/60)"
    sleep 10
  done

  echo "deployment/${deployment} was not created within 10 minutes"
  return 1
}

oc wait crd/dscinitializations.dscinitialization.opendatahub.io \
  --for=condition=Established --timeout=5m
oc wait crd/datascienceclusters.datasciencecluster.opendatahub.io \
  --for=condition=Established --timeout=5m

cat <<'EOF' | oc apply -f -
apiVersion: dscinitialization.opendatahub.io/v2
kind: DSCInitialization
metadata:
  name: default-dsci
spec:
  applicationsNamespace: opendatahub
  monitoring:
    managementState: Removed
    namespace: opendatahub
  trustedCABundle:
    managementState: Removed
---
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    mcplifecycleoperator:
      managementState: Managed
EOF

oc wait datasciencecluster/default-dsc \
  --for=jsonpath='{.status.components.mcplifecycleoperator.managementState}'=Managed \
  --timeout=15m
wait_for_deployment mcp-lifecycle-module-operator-controller-manager
wait_for_deployment mcp-lifecycle-operator-controller-manager

oc create namespace ocp-mcp-server
tls_dir=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "${tls_dir}/tls.key" -out "${tls_dir}/tls.crt" \
  -subj /CN=ocp-mcp-server.ocp-mcp-server.svc \
  -addext subjectAltName=DNS:ocp-mcp-server.ocp-mcp-server.svc,DNS:ocp-mcp-server.ocp-mcp-server.svc.cluster.local
cp "${tls_dir}/tls.crt" "${tls_dir}/ca.crt"
oc create secret generic ocp-mcp-server-tls -n ocp-mcp-server \
  --from-file="${tls_dir}/tls.crt" \
  --from-file="${tls_dir}/tls.key" \
  --from-file="${tls_dir}/ca.crt"

cat <<EOF | oc apply -f -
apiVersion: mcp.x-k8s.io/v1alpha1
kind: MCPServer
metadata:
  name: ocp-mcp-server
  namespace: ocp-mcp-server
spec:
  source:
    type: ContainerImage
    containerImage:
      ref: ${IMAGE_OPENSHIFT_MCP_SERVER}
  config:
    port: 8080
    arguments:
    - --port
    - "8080"
    - --read-only
    - --tls-cert
    - /tls/tls.crt
    - --tls-key
    - /tls/tls.key
    storage:
    - path: /tls
      source:
        type: Secret
        secret:
          secretName: ocp-mcp-server-tls
  transport:
    tls:
      enabled: true
      caBundleSecret:
        name: ocp-mcp-server-tls
EOF

oc wait mcpserver/ocp-mcp-server -n ocp-mcp-server \
  --for=condition=Ready --timeout=10m
