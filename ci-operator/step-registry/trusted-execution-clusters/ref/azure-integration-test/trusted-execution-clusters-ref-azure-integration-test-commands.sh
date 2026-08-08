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
export TEST_TIMEOUT_MULTIPLIER=2

az login --service-principal \
  -u "$(cat /tmp/secrets/azure/client-id)" \
  -p "$(cat /tmp/secrets/azure/client-secret)" \
  --tenant "$(cat /tmp/secrets/azure/tenant-id)"

eval "$(ssh-agent -s)"

git remote add test https://github.com/Jakob-Naucke/trusted-cluster-operator
git fetch test
git switch timed-client-ci

export REGISTRY=quay.io/jnaucke
export TAG=20260730-cd170d1
export INTEGRATION_TEST_THREADS=2

echo "[INFO] Install cert-manager"
CRT_MGR_VERSION=$(go list -m -f '{{.Version}}' github.com/cert-manager/cert-manager)
oc apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CRT_MGR_VERSION}/cert-manager.yaml"

echo "[INFO] Running integration tests until failure..."
while make integration-tests
do :
done
