#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# ---- k3s configuration ----
K3S_VERSION="${K3S_VERSION:-v1.31.6+k3s1}"
K3S_KUBECONFIG="/tmp/k3s-kubeconfig"
K3S_CONTAINER="k3s-mgmt"

# Pre-set USE_KUBECONFIG before sourcing env.sh to prevent it from
# defaulting to the IPI kubeconfig (${SHARED_DIR}/kubeconfig) which
# does not exist in k3s mode.
export USE_KUBECONFIG="${K3S_KUBECONFIG}"

source openshift-ci/capz-test-env.sh
set -o xtrace

# ---- Install podman (not present in the src image) ----
if ! command -v podman &>/dev/null; then
  echo "[k3s] Installing podman"
  chmod -R u+w /etc/yum.repos.art/ci/ 2>/dev/null || true
  dnf install -y podman
fi

# ---- Cleanup on exit ----
cleanup_k3s() {
  echo "[k3s] Stopping k3s container"
  podman stop "${K3S_CONTAINER}" 2>/dev/null || true
  podman rm -f "${K3S_CONTAINER}" 2>/dev/null || true
}
trap cleanup_k3s EXIT

# ---- Start k3s in a privileged podman container ----
# CI pods run as non-root but nested_podman provides the capabilities
# needed to run podman. Running k3s inside a privileged container
# gives it root access and full control over sysctls/networking.
echo "[k3s] Starting k3s ${K3S_VERSION} via podman (privileged)"

podman run -d --name "${K3S_CONTAINER}" \
  --privileged \
  --network=host \
  --cgroupns=host \
  -v /tmp:/tmp \
  docker.io/rancher/k3s:"${K3S_VERSION}" \
  server \
  --disable=traefik \
  --snapshotter=native \
  --write-kubeconfig="${K3S_KUBECONFIG}" \
  --write-kubeconfig-mode=644 \
  --kubelet-arg="eviction-hard=imagefs.available<1%,nodefs.available<1%" \
  --kubelet-arg="eviction-minimum-reclaim=imagefs.available=1%,nodefs.available=1%"

echo "[k3s] Waiting for k3s to be ready"
READY=false
for i in $(seq 1 60); do
  if ! podman ps --filter "name=${K3S_CONTAINER}" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
    echo "[k3s] FATAL: k3s container died unexpectedly"
    podman logs "${K3S_CONTAINER}" 2>&1 | tail -20
    exit 1
  fi
  if KUBECONFIG="${K3S_KUBECONFIG}" kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready"; then
    READY=true
    break
  fi
  sleep 5
  echo "[k3s] ... waiting ($((i*5))s)"
done

if [ "${READY}" != true ]; then
  echo "[k3s] FATAL: k3s did not become ready within 300s"
  podman logs "${K3S_CONTAINER}" 2>&1 | tail -50
  exit 1
fi
echo "[k3s] Server is ready"
KUBECONFIG="${K3S_KUBECONFIG}" kubectl get nodes

# ---- Configure test suite to use k3s ----
export DEPLOY_CHARTS="true"
export USE_K8S="false"

# ---- Install gotestsum ----
GOFLAGS='' go install gotest.tools/gotestsum@v1.13.0
export PATH="${GOBIN:-$(go env GOPATH)/bin}:${PATH}"

# ---- Run e2e test phases ----
echo "[k3s] Running e2e test phases 01-08"
gotestsum --junitfile="${ARTIFACT_DIR}/junit-e2e.xml" -- \
  -v ./test -count=1 -timeout 150m
