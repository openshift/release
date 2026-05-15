#!/bin/bash

set -euo pipefail

curl https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
export PATH="$HOME/.local/bin:$PATH"
unset GOFLAGS

pip install azure-cli

AZURE_SUBSCRIPTION_ID=$(cat /tmp/secrets/azure/subscription-id)
TEST_IMAGE=$(cat /tmp/secrets/azure/test-image)
TEST_NAMESPACE_PREFIX="ci-${PULL_NUMBER:+${PULL_NUMBER}-}$(uuidgen | cut -d- -f1)-"
export AZURE_SUBSCRIPTION_ID TEST_IMAGE TEST_NAMESPACE_PREFIX

export VIRT_PROVIDER=azure
export PLATFORM=openshift

az login --service-principal \
  -u "$(cat /tmp/secrets/azure/client-id)" \
  -p "$(cat /tmp/secrets/azure/client-secret)" \
  --tenant "$(cat /tmp/secrets/azure/tenant-id)"

eval "$(ssh-agent -s)"

echo "[INFO] Install cert-manager"
CRT_MGR_VERSION=$(go list -m -f '{{.Version}}' github.com/cert-manager/cert-manager)
oc apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CRT_MGR_VERSION}/cert-manager.yaml"

echo "[INFO] Running integration tests..."
make integration-tests
