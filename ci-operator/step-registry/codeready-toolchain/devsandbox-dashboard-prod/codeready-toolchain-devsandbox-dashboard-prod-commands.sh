#!/bin/bash
set -euo pipefail

export KUBECONF=/tmp/kubeconfig
cat /usr/local/sandbox-secrets/KUBECONFIG_E2E_TESTS 2>/dev/null | base64 -d > "${KUBECONF}"
make test-devsandbox-dashboard-e2e-prod \
  KUBECONFIG="${KUBECONF}"
