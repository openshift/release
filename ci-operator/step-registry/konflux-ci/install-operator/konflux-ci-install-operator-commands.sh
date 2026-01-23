#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Installing Konflux using the operator-based approach..."

# Configuration - can be overridden via env vars
KONFLUX_BRANCH="${KONFLUX_BRANCH:-main}"
KONFLUX_OPERATOR_REGISTRY="${KONFLUX_OPERATOR_REGISTRY:-quay.io/redhat-user-workloads/konflux-vanguard-tenant}"

# Clone the konflux-ci repository at the specified branch
cd "$(mktemp -d)"
echo "Cloning konflux-ci repository (branch: ${KONFLUX_BRANCH})..."
git clone --depth 1 --branch "${KONFLUX_BRANCH}" https://github.com/konflux-ci/konflux-ci.git .

# Get the commit SHA to construct the image tag
COMMIT_SHA=$(git rev-parse HEAD)
OPERATOR_IMAGE="${KONFLUX_OPERATOR_REGISTRY}/konflux-operator:on-pr-${COMMIT_SHA}"
echo "Using operator image: ${OPERATOR_IMAGE}"

# Step 1: Deploy dependencies (skip operator-managed components)
echo "Deploying dependencies..."
SKIP_DEX=true \
SKIP_KONFLUX_INFO=true \
SKIP_CLUSTER_ISSUER=true \
SKIP_INTERNAL_REGISTRY=true \
./deploy-deps.sh

# Step 2: Install CRDs from the checked-out branch
echo "Installing Operator CRDs..."
cd operator
make install

# Step 3: Deploy the operator using the Konflux-built image
echo "Deploying Operator (image: ${OPERATOR_IMAGE})..."
make deploy IMG="${OPERATOR_IMAGE}"

# Step 4: Wait for the operator to be ready
echo "Waiting for Konflux Operator to be ready..."
kubectl wait --for=condition=Available deployment/konflux-operator-controller-manager -n konflux-operator --timeout=300s

# Step 5: Create Konflux CR instance
echo "Creating Konflux CR..."
kubectl apply -f config/samples/konflux_v1alpha1_konflux.yaml

echo "Konflux operator installation complete. Use konflux-ci-wait-for-installation step to wait for Ready state."

