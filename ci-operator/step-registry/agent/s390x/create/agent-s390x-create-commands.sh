#!/bin/bash

set -x

export CLUSTER_NAME="my-ocp-419"
export CLUSTER_ARCH="s390x"
export CLUSTER_VERSION="4.19.0"
export CONTROL_NODE_COUNT=3
export COMPUTE_NODE_COUNT=3
export PULL_SECRET_FILE="$HOME/pull-secret"
export REGION="Frankfurt"
export RESOURCE_GROUP="hypershift"
export IC_API_KEY="OqwH-09V36csYFRPzLcrV_m2WMBCK3zC4vb2_ht4sSNh"

# Path to your private SSH key
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"

# Git repository URL (SSH format)
REPO_URL="git@github.ibm.com:OpenShift-on-Z/ibmcloud-openshift-provisioning.git"

# Target directory
CLONE_DIR="ibmcloud-openshift-provisioning"

# Run the clone
GIT_SSH_COMMAND="ssh -i $SSH_KEY_PATH -o IdentitiesOnly=yes -o StrictHostKeyChecking=no" \
git clone "$REPO_URL"

#Navigate to clone directory
cd "$CLONE_DIR" || {
    echo "❌ Failed to cd into $CLONE_DIR"
    exit 1
}

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

echo "Printing arch"
echo $CLUSTER_ARCH
 
# Run the create-cluster.sh script to create the OCP cluster in IBM cloud VPC
if [[ -x ./create-cluster.sh ]]; then
    ./create-cluster.sh
else
    echo "❌ create-cluster.sh not found or not executable"
    exit 1
fi
