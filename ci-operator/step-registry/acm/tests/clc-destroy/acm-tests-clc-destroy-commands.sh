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

# Wait for the cluster API server to become reachable.
# This is a best-effort cleanup step (no errexit), so exit 0 if
# the API never comes back — we cannot clean up a cluster we
# cannot reach.
wait_for_api() {
    local retries=20
    local delay=15
    echo "Waiting for cluster API to become reachable..."
    for i in $(seq 1 "${retries}"); do
        if oc get --raw=/version &>/dev/null; then
            echo "Cluster API is reachable."
            return 0
        fi
        echo "  Attempt ${i}/${retries}: API not reachable, retrying in ${delay}s..."
        sleep "${delay}"
    done
    echo "WARNING: Cluster API not reachable after $(( retries * delay ))s — skipping cleanup."
    exit 0
}

wait_for_api

cp ${SECRETS_DIR}/clc-interop/secret-options-yaml ./options.yaml

# Set the dynamic vars based on provisioned hub cluster.
CYPRESS_CLC_OCP_IMAGE_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | sed 's/[^0-9.]*\([0-9.]*\).*/\1/')
export CYPRESS_CLC_OCP_IMAGE_VERSION

CYPRESS_BASE_URL=$(oc whoami --show-console)
export CYPRESS_BASE_URL

CYPRESS_HUB_API_URL=$(oc whoami --show-server)
export CYPRESS_HUB_API_URL

CYPRESS_OPTIONS_HUB_PASSWORD=$(cat $SHARED_DIR/kubeadmin-password)
export CYPRESS_OPTIONS_HUB_PASSWORD

CLOUD_PROVIDERS=$(cat $SECRETS_DIR/clc/ocp_cloud_providers)
export CLOUD_PROVIDERS

# run the test execution script
./execute_clc_interop_commands.sh || :

cp -r reports $ARTIFACT_DIR/
