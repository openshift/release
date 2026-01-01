#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

# Verify promtool is available
promtool --version

# Configure bicep to use system path
az config set bicep.use_binary_from_path=true
az bicep version

# Run alerts generation
cd observability
make alerts

# Check for uncommitted changes
if [[ ! -z "$(git status --short)" ]]; then
  echo "there are some modified files, rerun 'make alerts' to update them and check the changes in"
  git status
  exit 1
fi

