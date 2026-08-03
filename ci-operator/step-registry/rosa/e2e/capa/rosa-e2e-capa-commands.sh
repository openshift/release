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
QUAY_USER=$(cat /var/run/rosa-hcp-e2e-secrets/quayUsername)
QUAY_PASS=$(cat /var/run/rosa-hcp-e2e-secrets/quayPassword)
AWS_ACCESS_KEY_ID=$(grep aws_access_key_id /var/run/rosa-e2e-aws-creds/awsEncodedCredentials | awk -F= '{print $2}' | tr -d ' ')
AWS_SECRET_ACCESS_KEY=$(grep aws_secret_access_key /var/run/rosa-e2e-aws-creds/awsEncodedCredentials | awk -F= '{print $2}' | tr -d ' ')
AWS_ACCOUNT_ID=$(cat /var/run/rosa-e2e-aws-creds/awsAccountId)
export OCM_CLIENT_ID OCM_CLIENT_SECRET OCM_API_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_ACCOUNT_ID
export QUAY_USER QUAY_PASS

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

# Install jq
if ! command -v jq &>/dev/null; then
  echo "Installing jq..."
  JQ_SHA256="5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"
  mkdir -p /tmp/bin
  curl -fsSL --connect-timeout 30 --max-time 60 --retry 3 \
    "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64" -o /tmp/bin/jq
  echo "${JQ_SHA256}  /tmp/bin/jq" | sha256sum --check --status || {
    echo "ERROR: jq checksum verification failed" >&2
    exit 1
  }
  chmod +x /tmp/bin/jq
  export PATH="/tmp/bin:$PATH"
  echo "jq installed: $(jq --version)"
else
  echo "jq already installed: $(jq --version)"
fi

# Install helm
if ! command -v helm &>/dev/null; then
  echo "Installing helm..."
  HELM_VERSION="3.17.3"
  HELM_SHA256="ee88b3c851ae6466a3de507f7be73fe94d54cbf2987cbaa3d1a3832ea331f2cd"
  HELM_ARCHIVE="helm-v${HELM_VERSION}-linux-amd64.tar.gz"
  curl -fsSL --connect-timeout 30 --max-time 120 --retry 3 \
    "https://get.helm.sh/${HELM_ARCHIVE}" -o "/tmp/${HELM_ARCHIVE}"
  echo "${HELM_SHA256}  /tmp/${HELM_ARCHIVE}" | sha256sum --check --status || {
    echo "ERROR: helm checksum verification failed" >&2
    exit 1
  }
  tar -xzf "/tmp/${HELM_ARCHIVE}" -C /tmp
  mkdir -p /tmp/bin
  mv /tmp/linux-amd64/helm /tmp/bin/helm
  chmod +x /tmp/bin/helm
  export PATH="/tmp/bin:$PATH"
  rm -rf "/tmp/${HELM_ARCHIVE}" "/tmp/${HELM_ARCHIVE}.sha256sum" /tmp/linux-amd64
  echo "Helm installed: $(helm version --short)"
else
  echo "Helm already installed: $(helm version --short)"
fi

# Export test env variables.
export DEPLOYMENT_MODE

# Generate a unique 4-char prefix per run to avoid IAM role name collisions
NAME_PREFIX="ci$(head -c 2 /dev/urandom | od -An -tx1 | tr -d ' ')"

echo "Running rosa-hcp-e2e tests (name_prefix=${NAME_PREFIX})..."
"${PYTHON}" run-test-suite.py ${TEST_SUITE} --ai-agent -e name_prefix="${NAME_PREFIX}" 2>&1 | tee "${ARTIFACT_DIR}/rosa-hcp-e2e-test.log"

echo "Tests complete. Results at ${ARTIFACT_DIR}/rosa-hcp-e2e-test.log"
