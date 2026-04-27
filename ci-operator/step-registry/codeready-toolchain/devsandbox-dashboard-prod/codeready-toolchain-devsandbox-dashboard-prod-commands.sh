#!/bin/bash
set -euo pipefail

export KUBECONF=/tmp/kubeconfig
printf '%s' "${KUBECONFIG}" | base64 -d > "${KUBECONF}"
make test-devsandbox-dashboard-in-container-prod \
  SSO_USERNAME="${SSO_USERNAME}" \
  SSO_PASSWORD="${SSO_PASSWORD}" \
  KUBECONFIG="${KUBECONF}"
