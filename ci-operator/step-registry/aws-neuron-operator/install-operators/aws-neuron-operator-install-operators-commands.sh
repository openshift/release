#!/bin/bash
set -euo pipefail

echo "Installing AWS Neuron Operator and dependencies"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

make cluster-operators
