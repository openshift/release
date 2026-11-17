#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# ---- Kind configuration ----
KIND_VERSION="${KIND_VERSION:-v0.31.0}"
KIND_KUBECONFIG="/tmp/kind-kubeconfig"

# Pre-set USE_KUBECONFIG before sourcing env.sh to prevent it from
# defaulting to the IPI kubeconfig (${SHARED_DIR}/kubeconfig) which
# does not exist in Kind mode.
export USE_KUBECONFIG="${KIND_KUBECONFIG}"

source openshift-ci/capz-test-env.sh
set -o xtrace

# ---- Cleanup on exit ----
cleanup_kind() {
  echo "[kind] Deleting kind cluster"
  kind delete cluster 2>/dev/null || true
}
trap cleanup_kind EXIT

# ---- Prepare kind cluster config ----
# KubeletInUserNamespace is required for rootless podman — kubelet
# cannot access /dev/kmsg in a user namespace without this gate.
# See https://github.com/adelton/kind-in-pod
cat > /tmp/kind-cluster.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        feature-gates: KubeletInUserNamespace=true
networking:
  apiServerAddress: 127.0.0.1
EOF

# ---- Create kind cluster ----
echo "[kind] Creating kind cluster"
kind create cluster --config /tmp/kind-cluster.yaml --kubeconfig "${KIND_KUBECONFIG}" --wait 5m

echo "[kind] Cluster is ready"
KUBECONFIG="${KIND_KUBECONFIG}" kubectl get nodes

# ---- Configure test suite to use kind ----
export DEPLOY_CHARTS="true"
export USE_K8S="false"

# ---- Install gotestsum ----
GOFLAGS='' GOPATH=/tmp/go GOBIN=/tmp GOCACHE=/tmp/go-cache go install gotest.tools/gotestsum@v1.13.0

# ---- Run e2e test phases ----
echo "[kind] Running e2e test phases 01-08"
gotestsum --junitfile="${ARTIFACT_DIR}/junit-e2e.xml" -- \
  -v ./test -count=1 -timeout 150m
