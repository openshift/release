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
oc get secret/pull-secret -n openshift-config --template='{{index .data ".dockerconfigjson" | base64decode}}' >"${CLUSTER_PULL_SECRET_ORIGINAL}"

echo "2. Isolating registry.redhat.io entry from CI credentials..."
REDHAT_AUTH_ENTRY=$(jq -r '.auths."registry.redhat.io"' "${CI_AUTH_PATH}")
if [[ "$REDHAT_AUTH_ENTRY" == "null" ]]; then
	echo "ERROR: registry.redhat.io credentials not found in mounted secret. Check platform configuration."
	exit 1
fi

echo "$REDHAT_AUTH_ENTRY" | jq '{ "auths": { "registry.redhat.io": . } }' >"${REDHAT_AUTH_FRAGMENT}"

echo "3. Merging credentials into the cluster pull secret..."
jq -s '.[0] * .[1]' "${CLUSTER_PULL_SECRET_ORIGINAL}" "${REDHAT_AUTH_FRAGMENT}" >"${CLUSTER_PULL_SECRET_UPDATED}"

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
cat <<EOF | oc apply -f -
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

echo "7. Verifying CatalogSource status..."
# Wait for the CatalogSource to be created and have a state
TIMEOUT=300
INTERVAL=10
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
	CATALOG_STATE=$(oc get catalogsource redhat-operators -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)

	if [[ "$CATALOG_STATE" == "READY" ]]; then
		echo "CatalogSource is READY"
		break
	elif [[ "$CATALOG_STATE" == "" ]]; then
		echo "Waiting for CatalogSource status to be populated... (${ELAPSED}s/${TIMEOUT}s)"
	else
		echo "CatalogSource state: ${CATALOG_STATE} (${ELAPSED}s/${TIMEOUT}s)"
	fi

	sleep $INTERVAL
	ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
	echo "ERROR: CatalogSource did not become READY within ${TIMEOUT} seconds"
	oc get catalogsource redhat-operators -n openshift-marketplace -o yaml
	exit 1
fi

echo "8. Verifying catalog pod is running and ready..."
# Wait for the catalog pod to be created and become ready
TIMEOUT=300
ELAPSED=0
RUNNING=false

while [ $ELAPSED -lt $TIMEOUT ]; do
	POD_NAME=$(oc get pods -n openshift-marketplace -l olm.catalogSource=redhat-operators -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

	if [[ -z "$POD_NAME" ]]; then
		echo "Waiting for catalog pod to be created... (${ELAPSED}s/${TIMEOUT}s)"
		sleep $INTERVAL
		ELAPSED=$((ELAPSED + INTERVAL))
		continue
	fi

	POD_PHASE=$(oc get pod "$POD_NAME" -n openshift-marketplace -o jsonpath='{.status.phase}' 2>/dev/null || true)
	POD_READY=$(oc get pod "$POD_NAME" -n openshift-marketplace -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)

	echo "Catalog pod: ${POD_NAME}, Phase: ${POD_PHASE}, Ready: ${POD_READY} (${ELAPSED}s/${TIMEOUT}s)"

	if [[ "$POD_PHASE" == "Running" ]] && [[ "$POD_READY" == "True" ]]; then
		echo "Catalog pod is running and ready"
		RUNNING=true
		break
	fi

	# Check if pod is in a failed state
	if [[ "$POD_PHASE" == "Failed" ]] || [[ "$POD_PHASE" == "CrashLoopBackOff" ]]; then
		echo "ERROR: Catalog pod is in a failed state: ${POD_PHASE}"
		oc get pod "$POD_NAME" -n openshift-marketplace -o yaml
		oc logs "$POD_NAME" -n openshift-marketplace --tail=50 || true
		exit 1
	fi

	sleep $INTERVAL
	ELAPSED=$((ELAPSED + INTERVAL))
done

if ! $RUNNING; then
	exit 1
fi

echo "Catalog source setup complete for cluster version ${OCP_MAJOR_MINOR}."
