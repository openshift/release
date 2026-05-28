#!/usr/bin/env bash

set -euo pipefail

# Validate KUBECONFIG is set
if [ -z "${KUBECONFIG:-}" ]; then
    echo "ERROR: KUBECONFIG environment variable must be set"
    exit 1
fi

sleep 600
# Get console URL from the cluster
echo "Fetching console URL from cluster..."
CONSOLE_URL=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' || echo "")
if [ -z "${CONSOLE_URL}" ]; then
    echo "ERROR: Failed to get console URL from cluster"
    exit 1
fi
export CYPRESS_BASE_URL="https://${CONSOLE_URL}"
echo "Console URL: ${CYPRESS_BASE_URL}"

# Retrieve kubeadmin password from shared dir
KUBEADMIN_PASSWORD_FILE="${SHARED_DIR}/kubeadmin-password"
if [ ! -f "${KUBEADMIN_PASSWORD_FILE}" ]; then
    echo "ERROR: kubeadmin password file not found at ${KUBEADMIN_PASSWORD_FILE}"
    exit 1
fi

# Disable tracing to avoid leaking credentials
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
KUBEADMIN_PASSWORD=$(cat "${KUBEADMIN_PASSWORD_FILE}")
export CYPRESS_LOGIN_USERS="kubeadmin:${KUBEADMIN_PASSWORD}"
$WAS_TRACING && set -x

export CYPRESS_LOGIN_IDP="${CYPRESS_LOGIN_IDP:-kube:admin}"
export IS_OPENSHIFT=true
export CYPRESS_GREP_TAGS="${CYPRESS_GREP_TAGS:-@Network_Observability}"
export CYPRESS_KUBECONFIG_PATH="${KUBECONFIG}"


echo "Login IDP: ${CYPRESS_LOGIN_IDP}"
echo "Test filter: ${CYPRESS_GREP_TAGS}"

/opt/app-root/scripts/run-e2e-tests.sh
