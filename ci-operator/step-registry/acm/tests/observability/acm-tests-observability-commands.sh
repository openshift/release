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
    cp ${SECRETS_DIR}/ci/metadata $SHARED_DIR/metadata.json
fi 

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# The AWS secrets
PARAM_AWS_SECRET_ACCESS_KEY=$(cat $SECRETS_DIR/obs/aws-secret-access-key)
export PARAM_AWS_SECRET_ACCESS_KEY

PARAM_AWS_ACCESS_KEY_ID=$(cat $SECRETS_DIR/obs/aws-access-key-id)
export PARAM_AWS_ACCESS_KEY_ID

# Set the dynamic vars based on provisioned hub cluster.
OC_HUB_CLUSTER_API_URL=$(oc whoami --show-server)
export OC_HUB_CLUSTER_API_URL

# HUB_CLUSTER_NAME=${BASE_DOMAIN/.cspilp.interop.ccitredhat.com/}
HUB_CLUSTER_NAME=$(cat $SHARED_DIR/metadata.json |jq -r '.clusterName') 
export HUB_CLUSTER_NAME='local-cluster'

OC_HUB_CLUSTER_PASS=$(cat $SHARED_DIR/kubeadmin-password)
export OC_HUB_CLUSTER_PASS

CLOUD_PROVIDER=${CLOUD_PROVIDER:-}
export CLOUD_PROVIDER

set +x
   oc login ${OC_HUB_CLUSTER_API_URL} --insecure-skip-tls-verify=true -u kubeadmin -p ${OC_HUB_CLUSTER_PASS}
set -x

# Get the base domain from the API URL
# left_cut=${OC_HUB_CLUSTER_API_URL:12} # substring --> ${VAR:start_index:length} --> remove https://api.
# BASE_DOMAIN=${left_cut/:6443/} # replace :6433 with empty string
metadata=$(cat $SHARED_DIR/metadata.json)
echo $metadata

# BASE_DOMAIN=$(cat $SHARED_DIR/metadata.json |jq -r '.aws.clusterDomain')
DOMAIN=$(oc get ingress.config.openshift.io/cluster -ojson | jq -r '.spec.domain')
BASE_DOMAIN=$(echo $DOMAIN | sed 's/apps.//g')
echo $BASE_DOMAIN
export BASE_DOMAIN

# Set the dynamic vars needed to execute the Observability scenarios on the managed clusters
# MANAGED_CLUSTER_NAME=$(cat $SHARED_DIR/managed.cluster.name)
# export MANAGED_CLUSTER_NAME

# MANAGED_CLUSTER_BASE_DOMAIN=$(cat $SHARED_DIR/managed.cluster.base.domain)
# export MANAGED_CLUSTER_BASE_DOMAIN

# MANAGED_CLUSTER_USER=$(cat $SHARED_DIR/managed.cluster.username)
# export MANAGED_CLUSTER_USER

# MANAGED_CLUSTER_PASS=$(cat $SHARED_DIR/managed.cluster.password)
# export MANAGED_CLUSTER_PASS

# MANAGED_CLUSTER_API_URL=$(cat $SHARED_DIR/managed.cluster.api.url)
# export MANAGED_CLUSTER_API_URL

# Create a .kube directory inside the alabama dir
mkdir -p /alabama/.kube

# Copy Kubeconfig file to the directory where Obs is looking it up
cp ${SHARED_DIR}/kubeconfig ~/.kube/config

#
# Remove the ACM Subscription to allow Observability interop tests full control of operators
#
OUTPUT=$(oc get subscription.apps.open-cluster-management.io -n policies openshift-plus-sub 2>/dev/null || true)
if [[ "$OUTPUT" != "" ]]; then
        oc get subscription.apps.open-cluster-management.io -n policies openshift-plus-sub -o yaml > /tmp/acm-policy-subscription-backup.yaml
        oc delete subscription.apps.open-cluster-management.io -n policies openshift-plus-sub
fi

#
# Fix the test expectation from "!= 1" to "== 0" to handle multiple node results.
# There's currently a code-freeze in place before 2.15.1 release on 21st of Jan, merge is not allowed for now.
# PR has been blocked: https://github.com/stolostron/multicluster-observability-operator/pull/2303 
# So, update the related file in the running container for now.
#
echo "Applying fix for RBAC test to handle multiple node results..."
RBAC_TEST_FILE="/tmp/obs/tests/pkg/tests/observability_rbac_test.go"
if [[ -f "$RBAC_TEST_FILE" ]]; then
    cp "$RBAC_TEST_FILE" "${RBAC_TEST_FILE}.bak"
    sed -i 's/if len(res\.Data\.Result) != 1 {/if len(res.Data.Result) == 0 {/g' "$RBAC_TEST_FILE"
else
    echo "Warning: $RBAC_TEST_FILE not found, skipping fix"
fi

# run the test execution script
bash +x ./execute_obs_interop_commands.sh || :

#
# Restore the ACM subscription
#
if [[ -f /tmp/acm-policy-subscription-backup.yaml ]]; then
        oc apply -f /tmp/acm-policy-subscription-backup.yaml
fi

# Copy the test cases results to an external directory
cp -r tests/pkg/tests $ARTIFACT_DIR/

mv $ARTIFACT_DIR/tests/results.xml $ARTIFACT_DIR/tests/junit_results.xml
