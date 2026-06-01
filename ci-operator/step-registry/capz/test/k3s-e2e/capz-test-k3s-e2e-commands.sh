#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# ---- k3s configuration ----
K3S_VERSION="${K3S_VERSION:-v1.31.6+k3s1}"
K3S_KUBECONFIG="/tmp/k3s-kubeconfig"
K3S_DATA_DIR="/tmp/k3s-data"

# Pre-set USE_KUBECONFIG before sourcing env.sh to prevent it from
# defaulting to the IPI kubeconfig (${SHARED_DIR}/kubeconfig) which
# does not exist in k3s mode.
export USE_KUBECONFIG="${K3S_KUBECONFIG}"

source openshift-ci/capz-test-env.sh
set -o xtrace

# ---- Cleanup on exit ----
ROOTLESSKIT_PID=""
cleanup_k3s() {
  if [[ -n "${ROOTLESSKIT_PID}" ]]; then
    echo "[k3s] Stopping rootlesskit (PID: ${ROOTLESSKIT_PID})"
    kill "${ROOTLESSKIT_PID}" 2>/dev/null || true
    wait "${ROOTLESSKIT_PID}" 2>/dev/null || true
  fi
}
trap cleanup_k3s EXIT

# ---- Setup runtime directories ----
export XDG_RUNTIME_DIR="/tmp/run"
mkdir -p "${XDG_RUNTIME_DIR}" "${K3S_DATA_DIR}"

# ---- Install k3s binary ----
echo "[k3s] Installing k3s ${K3S_VERSION}"
K3S_URL="https://github.com/k3s-io/k3s/releases/download/$(echo "${K3S_VERSION}" | sed 's/+/%2B/')/k3s"
curl -sLo /tmp/k3s "${K3S_URL}"
chmod +x /tmp/k3s
export PATH="/tmp:${PATH}"
echo "[k3s] Installed: $(k3s --version)"

# ---- Install rootlesskit ----
echo "[k3s] Installing rootlesskit"
GOFLAGS='' GOPATH=/tmp/go GOBIN=/tmp GOCACHE=/tmp/go-cache go install github.com/rootless-containers/rootlesskit/v2/cmd/rootlesskit@latest

# ---- Prepare /dev/kmsg ----
ln -sf /dev/null /dev/kmsg 2>/dev/null || true

# ---- Start k3s inside rootlesskit namespace ----
# rootlesskit creates a user namespace (UID 0 mapping) + network namespace
# with slirp4netns connectivity. Inside that namespace:
# - ip_forward can be set to 1 (own network namespace)
# - iptables works (own network namespace with CAP_NET_ADMIN)
# - k3s runs as regular server (no --rootless needed)
echo "[k3s] Starting k3s via rootlesskit (slirp4netns networking)"

rootlesskit --net=slirp4netns --disable-host-loopback --state-dir=/tmp/rootlesskit-state \
  --copy-up=/etc --copy-up=/run --copy-up=/var/lib \
  sh -c '
    sysctl -w net.ipv4.ip_forward=1
    ln -sf /dev/null /dev/kmsg 2>/dev/null || true
    exec k3s server \
      --disable=traefik \
      --snapshotter=native \
      --data-dir='"${K3S_DATA_DIR}"' \
      --write-kubeconfig='"${K3S_KUBECONFIG}"' \
      --write-kubeconfig-mode=644 \
      --kubelet-arg="eviction-hard=imagefs.available<1%,nodefs.available<1%" \
      --kubelet-arg="eviction-minimum-reclaim=imagefs.available=1%,nodefs.available=1%"
  ' &
ROOTLESSKIT_PID=$!

echo "[k3s] Waiting for k3s to be ready (PID: ${ROOTLESSKIT_PID})"
READY=false
for i in $(seq 1 90); do
  if [[ ! -d "/proc/${ROOTLESSKIT_PID}" ]]; then
    echo "[k3s] FATAL: rootlesskit/k3s process died unexpectedly"
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
  echo "[k3s] FATAL: k3s did not become ready within 450s"
  exit 1
fi
echo "[k3s] Server is ready"
KUBECONFIG="${K3S_KUBECONFIG}" kubectl get nodes

# ---- Configure test suite to use k3s ----
export DEPLOY_CHARTS="true"
export USE_K8S="false"

# ---- Install gotestsum ----
GOFLAGS='' GOPATH=/tmp/go GOBIN=/tmp GOCACHE=/tmp/go-cache go install gotest.tools/gotestsum@v1.13.0

# ---- Run e2e test phases ----
echo "[k3s] Running e2e test phases 01-08"
gotestsum --junitfile="${ARTIFACT_DIR}/junit-e2e.xml" -- \
  -v ./test -count=1 -timeout 150m
