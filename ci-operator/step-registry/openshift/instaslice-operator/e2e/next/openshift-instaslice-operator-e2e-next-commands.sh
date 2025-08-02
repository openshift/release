#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECTL=oc
export DEPLOY_DIR=deploy
export IMAGE_REGISTRY="${IMAGE_REGISTRY}"
export IMAGE_TAG="${IMAGE_TAG}"
export EMULATED_MODE=${EMULATED_MODE}

TOOLS_DIR=/tmp/bin
JUST_VERSION=1.42.2
JUST_URL="https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz"

# Install tools
echo "Installing tools to deploy instaslice-operator"
mkdir -p "${TOOLS_DIR}"
# just
curl -L --retry 5 "${JUST_URL}" -o just.tar.gz
tar -xzf just.tar.gz -C "${TOOLS_DIR}" just
chmod +x "${TOOLS_DIR}/just"
rm just.tar.gz
echo "   just installed"

export PATH="${TOOLS_DIR}:${PATH}"

echo "Deploying instaslice-operator and executing e2e test suite"
just test-e2e-ci
