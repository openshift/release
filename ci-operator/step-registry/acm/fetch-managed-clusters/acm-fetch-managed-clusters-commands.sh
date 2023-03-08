
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

#export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Set the dynamic vars based on provisioned hub cluster.
#HUB_OCP_API_URL=$(oc whoami --show-console)
export HUB_OCP_API_URL="test_url"
#HUB_OCP_PASSWORD=$(cat $SHARED_DIR/kubeadmin-password)
export HUB_OCP_PASSWORD="TEST-PASSWORD-I-SHOULD-NOT-SEE-THIS-IN-OUTPUT"

sleep 1800

# run the test execution script
./ci/containerimages/fetch-managed-clusters/fetch_clusters_commands.sh

#cp -r /tmp/ci/managed.cluster.api.url $ARTIFACT_DIR/