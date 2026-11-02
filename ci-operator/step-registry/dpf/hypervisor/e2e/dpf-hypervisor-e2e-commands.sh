#!/bin/bash
set -euo pipefail

# Copy .env to working directory
cp "${SHARED_DIR}/.env" .env

echo "Setting up aicli offline token..."
install -d -m 700 "${HOME}/.aicli"
install -m 600 "${CLUSTER_PROFILE_DIR}/aicli-offlinetoken" "${HOME}/.aicli/offlinetoken.txt"
echo "aicli offline token configured"

echo "Verifying cluster access..."
oc get nodes

echo "=== Running DPF Kubernetes e2e Tests ==="
[[ -n "${E2E_GO_LABEL_FILTER}" ]] && export E2E_GO_LABEL_FILTER
make validate-env-test-files
make generate-env-test
make test-go-e2e
