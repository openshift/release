#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "DEBUG: Starting windows-conf-operator configuration"
echo "DEBUG: SUB_INSTALL_NAMESPACE=${SUB_INSTALL_NAMESPACE}"
echo "DEBUG: CLUSTER_PROFILE_DIR=${CLUSTER_PROFILE_DIR}"

# Check if private key exists
echo "DEBUG: Checking for ssh-privatekey..."
ls -l "${CLUSTER_PROFILE_DIR}/ssh-privatekey"

# Check namespace status
echo "DEBUG: Checking namespace status..."
if ! oc get ns "${SUB_INSTALL_NAMESPACE}"; then
  echo "DEBUG: Namespace ${SUB_INSTALL_NAMESPACE} not found, creating..."
  oc create ns "${SUB_INSTALL_NAMESPACE}"
else
  echo "DEBUG: Namespace ${SUB_INSTALL_NAMESPACE} already exists"
fi

# Enable monitoring with debug info
echo "DEBUG: Enabling monitoring for namespace..."
oc label namespace "${SUB_INSTALL_NAMESPACE}" openshift.io/cluster-monitoring=true
echo "DEBUG: Namespace labels after modification:"
oc get ns "${SUB_INSTALL_NAMESPACE}" --show-labels

# Create secret with debug info
echo "DEBUG: Creating cloud-private-key secret..."
oc create secret generic cloud-private-key \
  -n "${SUB_INSTALL_NAMESPACE}" \
  --from-file=private-key.pem="${CLUSTER_PROFILE_DIR}/ssh-privatekey"

# Verify secret creation
echo "DEBUG: Verifying secret creation..."
oc get secret cloud-private-key -n "${SUB_INSTALL_NAMESPACE}"

echo "DEBUG: windows-conf-operator configuration completed"
