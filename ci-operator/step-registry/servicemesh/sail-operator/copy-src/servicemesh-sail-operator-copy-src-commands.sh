#!/bin/bash

# ==============================================================================
# Source Code Copy Script
#
# This script copies source code and configuration files to a test pod
# running in an OpenShift cluster for testing purposes.
#
# It performs the following steps:
# 1. Copies the entire source directory contents to the test pod's /work/
#    directory, preserving the directory structure and file permissions.
# 2. Copies the current kubeconfig file to the test pod as ci-kubeconfig,
#    enabling the test pod to interact with the OpenShift cluster.
#
# Required Environment Variables:
#   - MAISTRA_NAMESPACE: The namespace where the test pod is running.
#   - MAISTRA_SC_POD: The name of the test pod to copy files to.
#   - KUBECONFIG: Path to the kubeconfig file for cluster access.
#
# Notes:
#   - The source path ends with "/." to copy directory contents rather than
#     the directory itself into the destination.
#   - Files are copied to /work/ in the test pod, which serves as the working
#     directory for test execution.
# ==============================================================================

set -o nounset
set -o errexit
set -o pipefail

echo "Copying source code to test pod..."

# SRC_PATH does end with /. : the content of the source directory is copied into dest directory
oc cp ./. "${MAISTRA_NAMESPACE}"/"${MAISTRA_SC_POD}":/work/

echo "Copying kubeconfig to test pod..."
oc cp ${KUBECONFIG} ${MAISTRA_NAMESPACE}/${MAISTRA_SC_POD}:/work/ci-kubeconfig

echo "Source copy completed successfully"