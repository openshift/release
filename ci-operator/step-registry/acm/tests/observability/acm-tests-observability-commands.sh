#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# The variables defined in this step come from files in the `SHARED_DIR` and credentials from Vault.
typeset secretsDir="/tmp/secrets"

# Get the creds from ACMQE CI vault and run the automation on pre-exisiting HUB
SKIP_OCP_DEPLOY="false"
if [[ $SKIP_OCP_DEPLOY == "true" ]]; then
    echo "------------ Skipping OCP Deploy = $SKIP_OCP_DEPLOY ------------"
    cp ${secretsDir}/ci/kubeconfig $SHARED_DIR/kubeconfig
    cp ${secretsDir}/ci/kubeadmin-password $SHARED_DIR/kubeadmin-password
    cp ${secretsDir}/ci/metadata $SHARED_DIR/metadata.json
fi 

: Copy kubeconfig to default location for kubectl/oc
mkdir -p ~/.kube
cp "${SHARED_DIR}/kubeconfig" ~/.kube/config

: Remove the ACM Subscription to allow Observability interop tests full control of operators
if oc get subscription.apps.open-cluster-management.io -n policies openshift-plus-sub -o yaml > /tmp/acm-policy-subscription-backup.yaml 2>/dev/null; then
    oc delete subscription.apps.open-cluster-management.io -n policies openshift-plus-sub
fi

# Credentials loaded with set +x to prevent exposure in CI logs
set +x
export PARAM_AWS_SECRET_ACCESS_KEY=
PARAM_AWS_SECRET_ACCESS_KEY="$(cat "${secretsDir}/obs/aws-secret-access-key")"

export PARAM_AWS_ACCESS_KEY_ID=
PARAM_AWS_ACCESS_KEY_ID="$(cat "${secretsDir}/obs/aws-access-key-id")"

export OC_HUB_CLUSTER_PASS=
OC_HUB_CLUSTER_PASS="$(cat "${SHARED_DIR}/kubeadmin-password")"

export MANAGED_CLUSTER_PASS=
MANAGED_CLUSTER_PASS="$(cat "${SHARED_DIR}/managed.cluster.password" 2>/dev/null || true)"
set -x

# Run Observability tests with all required environment variables
OC_CLUSTER_USER="kubeadmin" \
BASE_DOMAIN="$(oc get ingress.config.openshift.io/cluster -ojson | jq -r '.spec.domain | sub("apps\\."; "")')" \
OC_HUB_CLUSTER_API_URL="$(oc whoami --show-server)" \
HUB_CLUSTER_NAME="local-cluster" \
MANAGED_CLUSTER_API_URL="$(cat "${SHARED_DIR}/managed.cluster.api.url" 2>/dev/null || true)" \
MANAGED_CLUSTER_NAME="$(cat "${SHARED_DIR}/managed.cluster.name" 2>/dev/null || true)" \
MANAGED_CLUSTER_BASE_DOMAIN="$(cat "${SHARED_DIR}/managed.cluster.base.domain" 2>/dev/null || true)" \
MANAGED_CLUSTER_USER="$(cat "${SHARED_DIR}/managed.cluster.username" 2>/dev/null || true)" \
bash +x ./execute_obs_interop_commands.sh || :

unset PARAM_AWS_SECRET_ACCESS_KEY PARAM_AWS_ACCESS_KEY_ID OC_HUB_CLUSTER_PASS MANAGED_CLUSTER_PASS

: Restore the ACM subscription
if [[ -f /tmp/acm-policy-subscription-backup.yaml ]]; then
    oc apply -f /tmp/acm-policy-subscription-backup.yaml || :
fi

: Copy the test cases results to an external directory
cp -r tests/pkg/tests $ARTIFACT_DIR/

mv $ARTIFACT_DIR/tests/results.xml $ARTIFACT_DIR/tests/junit_results.xml

true
