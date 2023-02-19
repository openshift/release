#!/bin/bash

set -o verbose

ADMIN_PASSWORD=$(cat "${KUBEADMIN_PASSWORD_FILE}")
CLUSTER_API_URL=$(oc whoami --show-server)

export USER_NAME=kubeadmin
export PASSWORD="${ADMIN_PASSWORD}"
export API_URL="${CLUSTER_API_URL}"
export NAMESPACE=openshift-streams
export KUBECONFIG=${SHARED_DIR}/kubeconfig

#/home/podman/.local/bin/poetry run python3 /home/podman/managed-services-integration-framework/ms-integration-framework/ms_interop_framework_execution_framework.py

sleep 50000
