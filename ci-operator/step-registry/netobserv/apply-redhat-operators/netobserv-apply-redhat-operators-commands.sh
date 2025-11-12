#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CI_AUTH_PATH="/var/run/secrets/ci-pull-credentials/.dockerconfigjson"

# Temporary files for processing
CLUSTER_PULL_SECRET_ORIGINAL="/tmp/cluster-pull-secret.json.orig"
REDHAT_AUTH_FRAGMENT="/tmp/redhat-auth-fragment.json"
CLUSTER_PULL_SECRET_UPDATED="/tmp/cluster-pull-secret.json.updated"

echo "1. Extracting current cluster pull secret..."
oc get secret/pull-secret -n openshift-config --template='{{index .data ".dockerconfigjson" | base64decode}}' > "${CLUSTER_PULL_SECRET_ORIGINAL}"

echo "2. Isolating registry.redhat.io entry from CI credentials..."
REDHAT_AUTH_ENTRY=$(jq -r '.auths."registry.redhat.io"' "${CI_AUTH_PATH}")
if [[ "$REDHAT_AUTH_ENTRY" == "null" ]]; then
    echo "ERROR: registry.redhat.io credentials not found in mounted secret. Check platform configuration."
    exit 1
fi

echo "$REDHAT_AUTH_ENTRY" | jq '{ "auths": { "registry.redhat.io": . } }' > "${REDHAT_AUTH_FRAGMENT}"


echo "3. Merging credentials into the cluster pull secret..."
jq -s '.[0] * .[1]' "${CLUSTER_PULL_SECRET_ORIGINAL}" "${REDHAT_AUTH_FRAGMENT}" > "${CLUSTER_PULL_SECRET_UPDATED}"

echo "4. Updating cluster global pull secret in openshift-config..."
# Apply the merged secret back to the cluster
oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="${CLUSTER_PULL_SECRET_UPDATED}"

# --- Dynamic Version Detection ---

# echo "5. Detecting OpenShift Cluster Version..."
OCP_MAJOR_MINOR=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d '.' -f1,2)
REDHAT_OPERATOR_INDEX_VERSION="v${OCP_MAJOR_MINOR}"

echo "Detected OCP version: ${OCP_MAJOR_MINOR}. Using index tag: ${REDHAT_OPERATOR_INDEX_VERSION}"

# --- Applying Catalog Source ---

echo "6. Applying redhat-operators CatalogSource using detected version..."

# Use the shell variable (${REDHAT_OPERATOR_INDEX_VERSION}) inside the manifest definition 
cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: redhat-operators
  namespace: openshift-marketplace
spec:
  displayName: Red Hat Operators
  publisher: Red Hat
  sourceType: grpc
  image: registry.redhat.io/redhat/redhat-operator-index:${REDHAT_OPERATOR_INDEX_VERSION}
  updateStrategy:
    registryPoll:
      interval: 45m
EOF

echo "Catalog source setup complete for cluster version ${OCP_MAJOR_MINOR}."
