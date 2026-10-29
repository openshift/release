#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

export AZURE_TOKEN_CREDENTIALS=prod

# Verify promtool is available
promtool --version

# Configure bicep to use system path
az config set bicep.use_binary_from_path=true
az bicep version

# Run alerts generation and testing
# TODO: remove fallback once https://github.com/Azure/ARO-HCP/pull/5900 is merged
cd observability
if make -n test-alerts &>/dev/null; then
  make test-alerts
  ALERT_TARGET="test-alerts"
else
  make alerts
  ALERT_TARGET="alerts"
fi

# Check for uncommitted changes
if [[ ! -z "$(git status --short)" ]]; then
  echo "there are some modified files, rerun 'make ${ALERT_TARGET}' to update them and check the changes in"
  git status
  exit 1
fi

