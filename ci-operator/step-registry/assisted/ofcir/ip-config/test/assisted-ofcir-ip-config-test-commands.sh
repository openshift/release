#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -x

echo "************ assisted-ofcir-ip-config deploy LCA command ************"

# shellcheck disable=SC1091
source "${SHARED_DIR}/packet-conf.sh"

REPO_URL="${LCA_REPO:-https://github.com/openshift-kni/lifecycle-agent.git}"
REPO_BRANCH="${LCA_BRANCH:-main}"

# Determine image to use. If not provided, use a local tag that may require registry configuration.
IMAGE_REF="${LCA_IMG:-localhost/lifecycle-agent:ci}"

REMOTE_ROOT="root@${IP}"

ssh "${SSHOPTS[@]}" "${REMOTE_ROOT}" bash -s <<'EOF'
set -euxo pipefail

# Ensure dependencies
if command -v dnf >/dev/null 2>&1; then
  PKG_MGR=dnf
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR=yum
else
  echo "Unsupported host: neither dnf nor yum found"
  exit 1
fi

\$PKG_MGR -y install git make podman

WORKDIR=/root/lifecycle-agent
if [ ! -d "\$WORKDIR" ]; then
  mkdir -p "\$WORKDIR"
fi
EOF

# Clone and checkout the repository on the host
ssh "${SSHOPTS[@]}" "${REMOTE_ROOT}" "test -d /root/lifecycle-agent/.git || git clone '${REPO_URL}' /root/lifecycle-agent"
ssh "${SSHOPTS[@]}" "${REMOTE_ROOT}" "cd /root/lifecycle-agent && git fetch origin '${REPO_BRANCH}' && git checkout -f '${REPO_BRANCH}' && git reset --hard 'origin/${REPO_BRANCH}'"

# Build the image and deploy
ssh "${SSHOPTS[@]}" "${REMOTE_ROOT}" bash -s <<EOF
set -euxo pipefail
cd /root/lifecycle-agent

# Try common operator-sdk style targets; fall back to podman build if not available
if grep -qE '^docker-build:|^image:' Makefile; then
  if grep -q '^docker-build:' Makefile; then
    make docker-build IMG="${IMAGE_REF}"
  else
    make image IMG="${IMAGE_REF}"
  fi
else
  # Fallback: build with podman in repo root
  if [ -f Dockerfile ] || [ -f docker/Dockerfile ] ; then
    DOCKERFILE="Dockerfile"
    [ -f docker/Dockerfile ] && DOCKERFILE="docker/Dockerfile"
    podman build -t "${IMAGE_REF}" -f "\${DOCKERFILE}" .
  else
    echo "No Makefile target or Dockerfile found to build the image"
    exit 1
  fi
fi

# Locate kubeconfig (common SNO locations). Allow override via env if already set.
if [ -z "\${KUBECONFIG:-}" ]; then
  for k in \\
    /root/kubeconfig \\
    /root/.kube/config \\
    /root/clusterconfig/auth/kubeconfig \\
    /root/dev-scripts/ocp/ostest/auth/kubeconfig \\
    /opt/openshift/auth/kubeconfig \\
    /etc/kubernetes/kubeconfig
  do
    if [ -f "\$k" ]; then
      export KUBECONFIG="\$k"
      break
    fi
  done
fi

if [ -z "\${KUBECONFIG:-}" ] || [ ! -f "\${KUBECONFIG}" ]; then
  echo "KUBECONFIG not found on host; cannot deploy operator"
  exit 1
fi

# Deploy operator
if grep -q '^deploy:' Makefile; then
  make deploy IMG="${IMAGE_REF}"
else
  IMG="${IMAGE_REF}" make deploy
fi
EOF

echo "************ assisted-ofcir-ip-config deploy LCA command: DONE ************"


