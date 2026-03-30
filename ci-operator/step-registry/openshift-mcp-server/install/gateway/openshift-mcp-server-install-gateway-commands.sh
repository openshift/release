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

echo "Installing Kuadrant MCP Gateway..."
command -v oc >/dev/null 2>&1 || {
  echo "ERROR: oc is required in the step image but was not found in PATH"
  exit 1
}
oc whoami >/dev/null 2>&1 || {
  echo "ERROR: oc is not authenticated; cannot continue"
  exit 1
}

function install_helm() {
  mkdir -p /tmp/helm
  curl -fsSL https://get.helm.sh/helm-v3.16.2-linux-amd64.tar.gz --output /tmp/helm/helm-v3.16.2-linux-amd64.tar.gz
  echo "9318379b847e333460d33d291d4c088156299a26cd93d570a7f5d0c36e50b5bb /tmp/helm/helm-v3.16.2-linux-amd64.tar.gz" | sha256sum --check --status
  (cd /tmp/helm && tar xvfpz helm-v3.16.2-linux-amd64.tar.gz)
  chmod +x /tmp/helm/linux-amd64/helm
  export PATH="/tmp/helm/linux-amd64:${PATH}"
}
helm version >/dev/null 2>&1 || install_helm

shim_dir=""
if ! command -v kubectl >/dev/null 2>&1; then
  shim_dir="$(mktemp -d)"
  ln -sf "$(command -v oc)" "${shim_dir}/kubectl"
  export PATH="${shim_dir}:${PATH}"
fi
d="$(mktemp -d)"
trap 'rm -rf "${d}"; [[ -n "${shim_dir}" ]] && rm -rf "${shim_dir}"' EXIT
curl -fsSL "https://github.com/Kuadrant/mcp-gateway/archive/refs/heads/main.tar.gz" | \
  tar -xz -C "${d}" --strip-components=1
(cd "${d}/config/openshift" && bash ./deploy_openshift.sh)

echo "Installing MCP Lifecycle Operator..."
oc apply -f "https://raw.githubusercontent.com/matzew/kubernetes-mcp-lifecycle-operator/refs/heads/distribution/dist/install.yaml"
echo "Waiting for MCP Lifecycle Operator deployment..."
oc -n mcp-lifecycle-operator-system rollout status deployment/mcp-lifecycle-operator-controller-manager --timeout=5m
# Listed in api-resources implies CRD is effective for clients (Established alone can still race discovery).
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
oc -n default get sa/mcp-viewer cm/kubernetes-mcp-server-config mcpserver/kubernetes-mcp-server

echo "Applying MCP gateway integration..."
wait_for_api_resource "mcp.kagenti.com" "mcpserverregistrations" 120 5
oc apply -f - <<'EOF'
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: kubernetes-mcp
  namespace: default
spec:
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: mcp-gateway
    namespace: gateway-system
  hostnames:
  - kubernetes-mcp.mcp.local
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /mcp
    backendRefs:
    - group: ""
      kind: Service
      name: kubernetes-mcp-server
      port: 8080
---
apiVersion: mcp.kagenti.com/v1alpha1
kind: MCPServerRegistration
metadata:
  name: kubernetes-mcp-server
  namespace: default
spec:
  toolPrefix: kube_
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: kubernetes-mcp
EOF

if ! oc -n default wait --for=condition=Ready mcpserverregistration/kubernetes-mcp-server --timeout=15m; then
  oc -n default get mcpserverregistration/kubernetes-mcp-server -o yaml || true
  exit 1
fi
