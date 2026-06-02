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

# ---- Fix subuid/subgid range for kind node images ----
# The nested-podman entrypoint sets subuid/subgid as user:1001:64535,
# which only covers container UIDs up to 64535. Kind's node image has
# files with GID 65534 (nobody) which can't be mapped in that range.
# The pod's user namespace limits host UIDs to 0-65535, so we can't
# extend past 65535. Split the range around our UID (1000) to cover
# UIDs 1-999 and 1001-65535, giving 65534 subordinate IDs total.
USER_NAME=$(whoami)
printf '%s\n' "${USER_NAME}:1:999" "${USER_NAME}:1001:64535" > /etc/subuid
printf '%s\n' "${USER_NAME}:1:999" "${USER_NAME}:1001:64535" > /etc/subgid

# ---- Configure podman for kind compatibility ----
# Kind requires private UTS namespace (to set hostname in node containers)
# and enabled cgroups (for kubelet cgroup management).
# See https://github.com/adelton/kind-in-pod
mkdir -p "${HOME}/.config/containers"
cat > "${HOME}/.config/containers/containers.conf" <<EOF
[containers]
utsns = "private"
cgroups = "enabled"
EOF

# ---- Install kind ----
echo "[kind] Installing kind ${KIND_VERSION}"
curl -sLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
chmod +x /tmp/kind
export PATH="/tmp:${PATH}"
echo "[kind] Installed: $(kind version)"

# ---- Set kind to use podman ----
export KIND_EXPERIMENTAL_PROVIDER=podman

# ---- Prepare kind cluster config ----
# KubeletInUserNamespace is required for rootless podman — kubelet
# cannot access /dev/kmsg in a user namespace without this gate.
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
  ipFamily: ipv4
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
