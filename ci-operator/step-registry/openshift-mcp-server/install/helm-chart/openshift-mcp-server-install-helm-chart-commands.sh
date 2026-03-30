#!/usr/bin/env bash
set -euo pipefail

: "${MCP_SERVER_IMAGE:?MCP_SERVER_IMAGE is required}"
echo "MCP_SERVER_IMAGE: ${MCP_SERVER_IMAGE}"

command -v oc >/dev/null 2>&1 || {
  echo "ERROR: oc is required in the step image but was not found in PATH"
  exit 1
}
oc whoami >/dev/null 2>&1 || {
  echo "ERROR: oc is not authenticated; cannot continue"
  exit 1
}

install_helm() {
  mkdir -p /tmp/helm
  curl -fsSL "https://get.helm.sh/helm-v3.16.2-linux-amd64.tar.gz" --output /tmp/helm/helm-v3.16.2-linux-amd64.tar.gz
  echo "9318379b847e333460d33d291d4c088156299a26cd93d570a7f5d0c36e50b5bb /tmp/helm/helm-v3.16.2-linux-amd64.tar.gz" | sha256sum --check --status
  (cd /tmp/helm && tar xvfpz helm-v3.16.2-linux-amd64.tar.gz)
  chmod +x /tmp/helm/linux-amd64/helm
  export PATH="/tmp/helm/linux-amd64:${PATH}"
}
helm version >/dev/null 2>&1 || install_helm

NS="openshift-mcp-server"
REL="mcp"
CHART="oci://ghcr.io/openshift/charts/openshift-mcp-server"

APP_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
HOST="${REL}.${APP_DOMAIN}"

if [[ "${MCP_SERVER_IMAGE}" == *@* ]]; then
  IMG_NAME="${MCP_SERVER_IMAGE%@*}"
  IMG_VERSION="${MCP_SERVER_IMAGE##*@}"
else
  IMG_NAME="${MCP_SERVER_IMAGE%:*}"
  IMG_VERSION="${MCP_SERVER_IMAGE##*:}"
fi
IMG_REGISTRY="${IMG_NAME%%/*}"
IMG_REPO="${IMG_NAME#*/}"

helm upgrade -i "${REL}" "${CHART}" \
  -n "${NS}" --create-namespace \
  --wait --timeout 15m \
  --set "ingress.host=${HOST}" \
  --set "image.registry=${IMG_REGISTRY}" \
  --set "image.repository=${IMG_REPO}" \
  --set "image.version=${IMG_VERSION}" \
  --set 'rbac.extraClusterRoleBindings[0].name=use-cluster-admin-role' \
  --set 'rbac.extraClusterRoleBindings[0].roleRef.name=cluster-admin' \
  --set 'rbac.extraClusterRoleBindings[0].roleRef.external=true' \
  --set 'config.read_only=false' \
  --set-string 'config.toolsets[0]=core' \
  --set-string 'config.toolsets[1]=config'

# --set-string 'config.toolsets[2]=helm'
# --set 'rbac.extraClusterRoleBindings[0].name=use-view-role'
# --set 'rbac.extraClusterRoleBindings[0].roleRef.name=view'
# --set 'rbac.extraClusterRoleBindings[0].roleRef.external=true'
 
DEPLOY="${REL}-redhat-openshift-mcp-server"
SA="$(oc -n "${NS}" get "deploy/${DEPLOY}" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"

echo "URL: https://${HOST}"
oc get deploy,po,svc,ingress -n "${NS}" -l "app.kubernetes.io/instance=${REL}" || true
oc rollout status "deployment/${DEPLOY}" -n "${NS}" --timeout=10m

if [[ -n "${SA}" ]]; then
  if oc auth can-i list pods --as="system:serviceaccount:${NS}:${SA}" -A >/dev/null 2>&1; then
    echo "RBAC check: SA ${NS}/${SA} can list pods cluster-wide (view binding effective)."
  else
    echo "WARN: SA ${NS}/${SA} still cannot list pods; check ClusterRoleBinding *-use-view-role or re-run helm upgrade." >&2
  fi
fi
