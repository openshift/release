#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# The variables defined in this step come from files in the `SHARED_DIR` and credentials from Vault.
SECRETS_DIR="/tmp/secrets"

# Set the dynamic vars based on provisioned hub cluster.
CYPRESS_OC_CLUSTER_URL=$(oc whoami --show-server)
export CYPRESS_OC_CLUSTER_URL

CYPRESS_BASE_URL=$(oc whoami --show-console)
export CYPRESS_BASE_URL

CYPRESS_OC_CLUSTER_PASS=$(cat $SHARED_DIR/kubeadmin-password)
export CYPRESS_OC_CLUSTER_PASS

# Set the dynamic vars needed to execute application based tests (GitOps, Ansible, ObjectStore, etc.)
ANSIBLE_TOKEN=$(cat $SECRETS_DIR/alc/ansible-token)
export ANSIBLE_TOKEN

CYPRESS_OBJECTSTORE_ACCESS_KEY=$(cat $SECRETS_DIR/alc/objectstore-access-key)
export CYPRESS_OBJECTSTORE_ACCESS_KEY

CYPRESS_OBJECTSTORE_SECRET_KEY=$(cat $SECRETS_DIR/alc/objectstore-secret-key)
export CYPRESS_OBJECTSTORE_SECRET_KEY

PRIVATE_GIT_URL=$(cat $SECRETS_DIR/alc/git-url)
export PRIVATE_GIT_URL

PRIVATE_GIT_USER=$(cat $SECRETS_DIR/alc/git-user)
export PRIVATE_GIT_USER

PRIVATE_GIT_TOKEN=$(cat $SECRETS_DIR/alc/git-token)
export PRIVATE_GIT_TOKEN

COLLECTIVE_OCP_TOKEN=$(cat $SECRETS_DIR/alc/collective-ocp-token)
export COLLECTIVE_OCP_TOKEN

# run the test execution script
./execute_alc_interop_commands.sh

# Copy the test cases results to an external directory
cp -r results $ARTIFACT_DIR/
