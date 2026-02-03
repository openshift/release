#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

az config set bicep.use_binary_from_path=true
az bicep version

# Run lint from dev-infrastructure
cd dev-infrastructure
make fmt
make lint

# Check for uncommitted changes
git diff --exit-code -- '***.bicep***' || (echo "Uncommitted changes detected in bicep templates" && exit 1)