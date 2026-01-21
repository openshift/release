#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Installing Konflux using the operator-based approach..."

# Clone the konflux-ci repository
cd "$(mktemp -d)"
git clone --depth 1 --branch main https://github.com/konflux-ci/konflux-ci.git .

# Step 1: Deploy dependencies (skip operator-managed components)
echo "Deploying dependencies..."
SKIP_DEX=true \
SKIP_KONFLUX_INFO=true \
SKIP_CLUSTER_ISSUER=true \
SKIP_INTERNAL_REGISTRY=true \
./deploy-deps.sh

# Step 2: Install the Konflux Operator from latest GitHub release
echo "Installing Konflux Operator..."
kubectl apply -f https://github.com/konflux-ci/konflux-ci/releases/latest/download/install.yaml

# Step 3: Wait for the operator to be ready
echo "Waiting for Konflux Operator to be ready..."
kubectl wait --for=condition=Available deployment/konflux-operator-controller-manager -n konflux-operator --timeout=300s

# Step 4: Deploy Konflux using the operator (apply Konflux CR)
echo "Deploying Konflux via operator..."
kubectl apply -f <(curl -L \
  https://github.com/konflux-ci/konflux-ci/releases/latest/download/samples.tar.gz | \
  tar -xzO ./konflux_v1alpha1_konflux.yaml)

echo "Konflux operator installation complete. Use konflux-ci-wait-for-installation step to wait for Ready state."

