#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# ---- k3s configuration ----
K3S_VERSION="${K3S_VERSION:-v1.31.6+k3s1}"
K3S_KUBECONFIG="/tmp/k3s-kubeconfig"

# Pre-set USE_KUBECONFIG before sourcing env.sh to prevent it from
# defaulting to the IPI kubeconfig (${SHARED_DIR}/kubeconfig) which
# does not exist in k3s mode.
export USE_KUBECONFIG="${K3S_KUBECONFIG}"

source openshift-ci/capz-test-env.sh
set -o xtrace

# ---- Cleanup on exit ----
K3S_PID=""
cleanup_k3s() {
  if [[ -n "${K3S_PID}" ]]; then
    echo "[k3s] Stopping k3s (PID: ${K3S_PID})"
    kill "${K3S_PID}" 2>/dev/null || true
    wait "${K3S_PID}" 2>/dev/null || true
  fi
}
trap cleanup_k3s EXIT

# ---- Install k3s ----
echo "[k3s] Installing k3s ${K3S_VERSION}"
K3S_URL="https://github.com/k3s-io/k3s/releases/download/$(echo "${K3S_VERSION}" | sed 's/+/%2B/')/k3s"
curl -sLo /tmp/k3s "${K3S_URL}"
chmod +x /tmp/k3s
export PATH="/tmp:${PATH}"
echo "[k3s] Installed: $(k3s --version)"

# ---- Start k3s ----
echo "[k3s] Starting k3s server"
ln -sf /dev/null /dev/kmsg 2>/dev/null || true

k3s server \
  --disable=traefik \
  --snapshotter=native \
  --write-kubeconfig="${K3S_KUBECONFIG}" \
  --write-kubeconfig-mode=644 \
  --kubelet-arg="eviction-hard=imagefs.available<1%,nodefs.available<1%" \
  --kubelet-arg="eviction-minimum-reclaim=imagefs.available=1%,nodefs.available=1%" \
  &
K3S_PID=$!

echo "[k3s] Waiting for k3s to be ready (PID: ${K3S_PID})"
READY=false
for i in $(seq 1 60); do
  if KUBECONFIG="${K3S_KUBECONFIG}" kubectl get nodes --no-headers 2>/dev/null | grep -q " Ready"; then
    READY=true
    break
  fi
  sleep 5
  echo "[k3s] ... waiting ($((i*5))s)"
done

if [ "${READY}" != true ]; then
  echo "[k3s] FATAL: k3s did not become ready within 300s"
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
