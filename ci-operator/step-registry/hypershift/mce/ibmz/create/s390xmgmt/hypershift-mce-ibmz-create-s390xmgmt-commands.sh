#!/bin/bash

set -ex
set -o pipefail

job_id=$(echo -n $PROW_JOB_ID|cut -c-8)
export job_id
export CLUSTER_NAME="hcp-s390x-mgmt-ci-$job_id"
CLUSTER_ARCH=s390x
export CLUSTER_ARCH
#export CLUSTER_VERSION="4.19.0"
cat "${AGENT_IBMZ_CREDENTIALS}/abi-pull-secret" | jq -c > "$HOME/pull-secret" 
export PULL_SECRET_FILE="$HOME/pull-secret"

CONTROL_NODE_PROFILE=cz2-16x32
export CONTROL_NODE_PROFILE
COMPUTE_NODE_PROFILE=cz2-16x32
export COMPUTE_NODE_PROFILE

echo "Printing OCP release image"
echo $OCP_RELEASE_IMAGE

ssh_key_string=$(cat "${AGENT_IBMZ_CREDENTIALS}/httpd-vsi-key")
export ssh_key_string
tmp_ssh_key="/tmp/ssh-private-key"
envsubst <<"EOF" >${tmp_ssh_key}
-----BEGIN OPENSSH PRIVATE KEY-----
${ssh_key_string}

-----END OPENSSH PRIVATE KEY-----
EOF
chmod 0600 ${tmp_ssh_key}

IC_API_KEY=$(cat "${AGENT_IBMZ_CREDENTIALS}/ibmcloud-apikey")
export IC_API_KEY

# Run the clone
GIT_SSH_COMMAND="ssh -i $tmp_ssh_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=no" \
git clone -b image-name-fix git@github.ibm.com:OpenShift-on-Z/ibmcloud-openshift-provisioning.git

#Navigate to clone directory
cd "ibmcloud-openshift-provisioning" || {
    echo "Failed to cd into ibmcloud-openshift-provisioning"
    exit 1
}



export OCP_RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:4.20.0-ec.5-s390x"

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

# Run the create-cluster.sh script to create the OCP cluster in IBM cloud VPC
if [[ -x ./create-cluster.sh ]]; then
    ./create-cluster.sh
else
    echo "create-cluster.sh not found or not executable"
    exit 1
fi



echo "Copying kubeconfig into SHARED_DIR"
cp "$HOME/$CLUSTER_NAME/auth/kubeconfig" "$SHARED_DIR/kubeconfig"
echo "Kubeconfig copied into SHARED_DIR"

echo "Getting default_os_images.json from assisted-service"
git clone https://github.com/openshift/assisted-service.git
cp ${HOME}/assisted-service/data/default_os_images.json ${SHARED_DIR}/default_os_images.json
