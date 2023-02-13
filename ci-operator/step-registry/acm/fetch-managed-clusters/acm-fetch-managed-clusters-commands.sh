#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Set the dynamic vars based on provisioned hub cluster.
HUB_OCP_API_URL=$(oc whoami --show-server)
export HUB_OCP_API_URL
HUB_OCP_PASSWORD=$(cat $SHARED_DIR/kubeadmin-password)
export HUB_OCP_PASSWORD

# run the test execution script
<<<<<<< HEAD
./fetch_clusters_commands.sh

if [ -s /tmp/ci/managed.cluster.name ] && ! grep -q "null" /tmp/ci/managed.cluster.name; then
    echo "managed.cluster.name file was found saving as artifact."
    cp -r /tmp/ci/managed.cluster.name $SHARED_DIR/
    cp -r /tmp/ci/managed.cluster.base.domain $SHARED_DIR/
    cp -r /tmp/ci/managed.cluster.api.url $SHARED_DIR/
    cp -r /tmp/ci/managed.cluster.username $SHARED_DIR/
    cp -r /tmp/ci/managed.cluster.password $SHARED_DIR/
else
    echo "managed.cluster.name file is empty, missing, or it contains null."
    echo "Failed to fetch managed clusters, killing job."
    exit 1
=======
./ci/containerimages/fetch-managed-clusters/fetch_clusters_commands.sh

if [ -s /tmp/ci/managed.cluster.name ] && ! grep -q "null" /tmp/ci/managed.cluster.name; then
    echo "managed.cluster.name file was found saving as artifact."
    cp -r /tmp/ci/managed.cluster.name ./
else
    echo "managed.cluster.name file is empty, missing, or it contains null."
    echo "Failed to fetch managed clusters, killing job."
    # could do exit, or pkill -f <filename>
    pkill -9 sh
>>>>>>> a274d34c640 (switch back to use official file path, add fetch cluster step.)
fi
