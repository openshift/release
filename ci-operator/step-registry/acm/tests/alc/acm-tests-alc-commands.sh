#!/bin/bash
set -o nounset
# set -o errexit
set -o pipefail

# The variables defined in this step come from files in the `SHARED_DIR` and credentials from Vault.
SECRETS_DIR="/tmp/secrets"

# Get the creds from ACMQE CI vault and run the automation on pre-exisiting HUB
SKIP_OCP_DEPLOY="false"
if [[ $SKIP_OCP_DEPLOY == "true" ]]; then
    echo "------------ Skipping OCP Deploy = $SKIP_OCP_DEPLOY ------------"
    cp ${SECRETS_DIR}/ci/kubeconfig $SHARED_DIR/kubeconfig
    cp ${SECRETS_DIR}/ci/kubeadmin-password $SHARED_DIR/kubeadmin-password
fi   

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Set the dynamic vars based on provisioned hub cluster.
CYPRESS_OC_CLUSTER_URL=$(oc whoami --show-server)
export CYPRESS_OC_CLUSTER_URL

CYPRESS_BASE_URL=$(oc whoami --show-console)
export CYPRESS_BASE_URL

CYPRESS_OC_CLUSTER_PASS=$(cat $SHARED_DIR/kubeadmin-password)
export CYPRESS_OC_CLUSTER_PASS

# Playwright equivalents (required by start.sh after Cypress→Playwright migration)
export HUB_URL=$(oc whoami --show-console)
export HUB_PASSWORD=$(cat $SHARED_DIR/kubeadmin-password)
export OC_CLUSTER_URL=$(oc whoami --show-server)
export OC_CLUSTER_PASS=$(cat $SHARED_DIR/kubeadmin-password)
export CONSOLE_USERNAME="${CYPRESS_OC_CLUSTER_USER:-kubeadmin}"
export TEST_MODE="${CYPRESS_TEST_MODE:-integration}"
export GREP="${TEST_TAGS:-@ocpInterop}"

# Set the dynamic vars needed to execute application based tests (GitOps, Ansible, ObjectStore, etc.)
ANSIBLE_TOKEN=$(cat $SECRETS_DIR/alc/ansible-token)
export ANSIBLE_TOKEN

CYPRESS_OBJECTSTORE_ACCESS_KEY=$(cat $SECRETS_DIR/alc/objectstore-access-key)
export CYPRESS_OBJECTSTORE_ACCESS_KEY

CYPRESS_OBJECTSTORE_SECRET_KEY=$(cat $SECRETS_DIR/alc/objectstore-secret-key)
export CYPRESS_OBJECTSTORE_SECRET_KEY

GITHUB_PRIVATE_URL=$(cat $SECRETS_DIR/alc/git-url)
export GITHUB_PRIVATE_URL

GITHUB_USER=$(cat $SECRETS_DIR/alc/git-user)
export GITHUB_USER

GITHUB_TOKEN=$(cat $SECRETS_DIR/alc/git-token)
export GITHUB_TOKEN

COLLECTIVE_OCP_TOKEN=$(cat $SECRETS_DIR/alc/collective-ocp-token)
export COLLECTIVE_OCP_TOKEN

# run the test execution script
./start.sh alc || :

# Copy test results (Playwright or legacy Cypress)
for dir in test-results playwright-report ../tests/cypress/results; do
  if [[ -d "$dir" ]]; then
    cp -r "$dir" "$ARTIFACT_DIR/" || true
  fi
done
