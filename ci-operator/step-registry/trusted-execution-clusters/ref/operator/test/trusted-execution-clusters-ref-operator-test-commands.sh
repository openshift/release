#!/bin/bash

set -euo pipefail

curl https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
unset GOFLAGS

VIRTCTL_VERSION=$(cd tools/virtctl && go list -m -f '{{.Version}}' kubevirt.io/kubevirt)
VIRTCTL_PATH=$HOME/.cargo/bin/virtctl
curl -Lo "$VIRTCTL_PATH" "https://github.com/kubevirt/kubevirt/releases/download/${VIRTCTL_VERSION}/virtctl-${VIRTCTL_VERSION}-linux-amd64"
chmod +x "$VIRTCTL_PATH"

export VIRT_PROVIDER=kubevirt
export PLATFORM=openshift

eval "$(ssh-agent -s)"

echo "[INFO] Install cert-manager"
CRT_MGR_VERSION=$(go list -m -f '{{.Version}}' github.com/cert-manager/cert-manager)
oc apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CRT_MGR_VERSION}/cert-manager.yaml"

echo "[INFO] Running integration tests..."
make integration-tests
