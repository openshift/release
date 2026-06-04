#!/bin/bash

set -ex
set -o pipefail

job_id=$(echo -n $PROW_JOB_ID|cut -c-8)
export job_id
export CLUSTER_NAME="${CLUSTER_NAME_PREFIX}-${job_id}"
CLUSTER_ARCH=s390x
export CLUSTER_ARCH
#export CLUSTER_VERSION="4.19.0"
cat "${AGENT_IBMZ_CREDENTIALS}/abi-pull-secret" | jq -c > "$HOME/pull-secret" 
export PULL_SECRET_FILE="$HOME/pull-secret"

ssh_key_string=$(cat "${OCP_ADDONS_CREDENTIALS}/httpd-vsi-key-addon-key")
export ssh_key_string
tmp_ssh_key="/tmp/ssh-private-key"
envsubst <<"EOF" >${tmp_ssh_key}
-----BEGIN OPENSSH PRIVATE KEY-----
${ssh_key_string}
-----END OPENSSH PRIVATE KEY-----
EOF
chmod 0600 ${tmp_ssh_key}

IC_API_KEY=$(cat "${OCP_ADDONS_CREDENTIALS}/ibmcloud-apikey-addon-key")
export IC_API_KEY

# Run the clone (fork + deploy key from httpd-vsi-key-addon-key in hypershift-agent-ibmz-credentials)
GIT_SSH_COMMAND="ssh -i $tmp_ssh_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=no" \
git clone -b image-name-fix git@github.ibm.com:Singana-Sivaram-Naidu/ibmcloud-openshift-provisioning.git

#Navigate to clone directory
cd "ibmcloud-openshift-provisioning" || {
    echo "Failed to cd into ibmcloud-openshift-provisioning"
    exit 1
}



#export OCP_RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:4.20.0-ec.5-s390x"

VARS_FILE="cluster-vars"

sed -i "s/^CLUSTER_NAME=.*/CLUSTER_NAME=\"$CLUSTER_NAME\"/" "$VARS_FILE"
sed -i "s/^CLUSTER_ARCH=.*/CLUSTER_ARCH=\"$CLUSTER_ARCH\"/" "$VARS_FILE"
sed -i "s/^CLUSTER_VERSION=.*/CLUSTER_VERSION=\"$CLUSTER_VERSION\"/" "$VARS_FILE"
sed -i "s/^CONTROL_NODE_COUNT=.*/CONTROL_NODE_COUNT=$CONTROL_NODE_COUNT/" "$VARS_FILE"
sed -i "s/^COMPUTE_NODE_COUNT=.*/COMPUTE_NODE_COUNT=$COMPUTE_NODE_COUNT/" "$VARS_FILE"
sed -i "s|^PULL_SECRET_FILE=.*|PULL_SECRET_FILE=\"$PULL_SECRET_FILE\"|" "$VARS_FILE"
sed -i "s/^REGION=.*/REGION=\"$REGION\"/" "$VARS_FILE"
sed -i "s/^RESOURCE_GROUP=.*/RESOURCE_GROUP=\"$RESOURCE_GROUP\"/" "$VARS_FILE"
sed -i "s/^IC_API_KEY=.*/IC_API_KEY=\"$IC_API_KEY\"/" "$VARS_FILE"
sed -i "s/^IC_CLI_VERSION=.*/IC_CLI_VERSION=\"$IC_CLI_VERSION\"/" "$VARS_FILE"
sed -i "s|^OCP_RELEASE_IMAGE=.*|OCP_RELEASE_IMAGE=\"$OCP_RELEASE_IMAGE\"|" "$VARS_FILE"
sed -i "s/^CONTROL_NODE_PROFILE=.*/CONTROL_NODE_PROFILE=\"$CONTROL_NODE_PROFILE\"/" "$VARS_FILE"
sed -i "s/^COMPUTE_NODE_PROFILE=.*/COMPUTE_NODE_PROFILE=\"$COMPUTE_NODE_PROFILE\"/" "$VARS_FILE"
sed -i "s/^VSI_IMAGE_NAME=.*/VSI_IMAGE_NAME=\"$VSI_IMAGE_NAME\"/" "$VARS_FILE"
sed -i "s/^ENABLE_NESTED_VIRT=.*/ENABLE_NESTED_VIRT=\"$ENABLE_NESTED_VIRT\"/" "$VARS_FILE"
sed -i "s/^CREATE_STORAGE_CLASS=.*/CREATE_STORAGE_CLASS=\"$CREATE_STORAGE_CLASS\"/" "$VARS_FILE"

# Draft/rehearsal-only: run mock unit tests (no IBM API). Set RUN_REHEARSAL_TESTS=1 in workflow env.
if [[ "${RUN_REHEARSAL_TESTS:-}" == "1" ]]; then
  echo "RUN_REHEARSAL_TESTS=1: running scripts/rehearsal-tests/run-all.sh"
  chmod +x scripts/rehearsal-tests/*.sh scripts/test-create-instance-retry.sh 2>/dev/null || true
  ./scripts/rehearsal-tests/run-all.sh
fi

# Rehearsal-only: inject one simulated IBM service_error so Prow logs prove retry logic.
# Enable with TEST_IBM_PROVISIONING_RETRY=1 in workflow env (remove before merging release PR).
if [[ "${TEST_IBM_PROVISIONING_RETRY:-}" == "1" ]]; then
  export IBM_INSTANCE_CREATE_FAIL_ONCE=1
  export IBM_INSTANCE_CREATE_RETRY_SLEEP_SEC="${IBM_INSTANCE_CREATE_RETRY_SLEEP_SEC:-5}"
  echo "TEST_IBM_PROVISIONING_RETRY=1: will simulate one transient instance-create failure (grep IBM_PROVISIONING_RETRY in log)"
fi

# Run the create-cluster.sh script to create the OCP cluster in IBM cloud VPC
if [[ -x ./create-cluster.sh ]]; then
    ./create-cluster.sh
else
    echo "create-cluster.sh not found or not executable"
    exit 1
fi


export mgmt_cluster_key=$CLUSTER_NAME
# Saving the cluster name and kubeconfig to SHARED_DIR
echo "$mgmt_cluster_key" >> "$SHARED_DIR/mgmt_cluster_name"

echo "Printing the management cluster name"
cat "$SHARED_DIR/mgmt_cluster_name"

echo "Copying kubeconfig into SHARED_DIR"
cp "$HOME/$CLUSTER_NAME/auth/kubeconfig" "$SHARED_DIR/kubeconfig"
echo "Kubeconfig copied into SHARED_DIR"

#Saving node keys to SHARED_DIR
cp "$HOME/$CLUSTER_NAME/.ssh/$CLUSTER_NAME-key" "$SHARED_DIR/$CLUSTER_NAME-key"
