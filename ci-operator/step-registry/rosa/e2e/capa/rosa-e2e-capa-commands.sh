#!/bin/bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Ansible requires Python, so it must be present in this image — fail fast if not.
PYTHON=$(command -v python3 || command -v python || true)
if [[ -z "${PYTHON}" ]]; then
  echo "ERROR: no python3 or python found in PATH" >&2
  exit 1
fi

# Load sensitive credentials from mounted secrets — disable tracing to prevent log exposure
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

OCM_CLIENT_ID=$(cat /var/run/rosa-hcp-e2e-secrets/ocmClientID)
OCM_CLIENT_SECRET=$(cat /var/run/rosa-hcp-e2e-secrets/ocmClientSecret)
OCM_API_URL=$(cat /var/run/rosa-hcp-e2e-secrets/ocmApiUrl)
AWS_B64ENCODED_CREDENTIALS=$(cat /var/run/rosa-e2e-aws-creds/awsEncodedCredentials)
export OCM_CLIENT_ID OCM_CLIENT_SECRET OCM_API_URL AWS_B64ENCODED_CREDENTIALS

$WAS_TRACING && set -x || true

# Clone rosa-hcp-e2e-test repository
WORK_DIR=$(mktemp -d)
echo "Cloning ${ROSA_HCP_E2E_REPO} (branch: ${ROSA_HCP_E2E_BRANCH})..."
git clone --depth=1 --branch "${ROSA_HCP_E2E_BRANCH}" "${ROSA_HCP_E2E_REPO}" "${WORK_DIR}/rosa-hcp-e2e-test"
cd "${WORK_DIR}/rosa-hcp-e2e-test"

# Install Python dependencies
if [[ -f "requirements.txt" ]]; then
  echo "Installing Python requirements..."
  "${PYTHON}" -m pip install -r requirements.txt
fi

# Install Ansible collection/role dependencies
if [[ -f "requirements.yml" ]]; then
  echo "Installing Ansible requirements..."
  ansible-galaxy install -r requirements.yml
fi

# Export test env variables.
export DEPLOYMENT_MODE

echo "Running rosa-hcp-e2e tests..."
"${PYTHON}" run-test-suite.py ${TEST_SUITE} 2>&1 | tee "${ARTIFACT_DIR}/rosa-hcp-e2e-test.log"

echo "Tests complete. Results at ${ARTIFACT_DIR}/rosa-hcp-e2e-test.log"
