#!/usr/bin/env bash
set -euo pipefail

: "${MCP_SERVER_IMAGE:?MCP_SERVER_IMAGE is required}"
echo "MCP_SERVER_IMAGE: ${MCP_SERVER_IMAGE}"

wait_for_api_resource() {
  local api_group=$1 plural=$2
  local timeout_sec=${3:-120} interval_sec=${4:-5}
  local elapsed=0

  while (( elapsed < timeout_sec )); do
    if oc api-resources --api-group="${api_group}" --no-headers 2>/dev/null \
      | awk -v want="${plural}" '$1 == want { f = 1 } END { exit !f }'
    then
      echo "API discovered: ${plural}.${api_group}"
      return 0
    fi
    sleep "${interval_sec}"
    (( elapsed += interval_sec ))
  done

  echo "ERROR: API not discovered within ${timeout_sec}s: ${plural}.${api_group}" >&2
  return 1
}

echo "Installing MCP Lifecycle Operator..."
oc apply -f "https://raw.githubusercontent.com/matzew/kubernetes-mcp-lifecycle-operator/refs/heads/distribution/dist/install.yaml"

echo "Waiting for MCP Lifecycle Operator deployment..."
oc -n mcp-lifecycle-operator-system rollout status deployment/mcp-lifecycle-operator-controller-manager --timeout=5m
wait_for_api_resource "mcp.x-k8s.io" "mcpservers" 120 5

echo "Creating MCP Server prerequisites..."
cat <<EOF | oc apply -f -
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: mcp-viewer
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: mcp-viewer-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - kind: ServiceAccount
    name: mcp-viewer
    namespace: default
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kubernetes-mcp-server-config
  namespace: default
data:
  config.toml: |
    log_level = 5
    port = "8080"
    read_only = true
    toolsets = ["core", "config"]
EOF

echo "Creating MCPServer resource..."
cat <<EOF | oc apply -f -
apiVersion: mcp.x-k8s.io/v1alpha1
kind: MCPServer
metadata:
  name: kubernetes-mcp-server
  namespace: default
spec:
  source:
    type: ContainerImage
    containerImage:
      ref: ${MCP_SERVER_IMAGE}
  config:
    port: 8080
    arguments:
      - --config
      - /etc/mcp-config/config.toml
    storage:
      - path: /etc/mcp-config
        source:
          type: ConfigMap
          configMap:
            name: kubernetes-mcp-server-config
  runtime:
    security:
      serviceAccountName: mcp-viewer
EOF

echo "Waiting for MCPServer to become ready..."
if ! oc -n default wait --for=condition=Ready mcpserver/kubernetes-mcp-server --timeout=10m; then
  oc -n default get mcpserver/kubernetes-mcp-server -o yaml || true
  exit 1
fi

echo "MCP Server installation objects:"
oc -n default get sa mcp-viewer
oc -n default get configmap kubernetes-mcp-server-config
oc -n default get mcpserver kubernetes-mcp-server
