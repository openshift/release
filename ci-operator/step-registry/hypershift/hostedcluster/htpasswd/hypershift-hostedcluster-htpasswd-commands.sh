#!/usr/bin/env bash
set -euo pipefail

echo HyperShift CLI version
/usr/bin/hypershift version

MGMT_KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
if [ ! -f "$MGMT_KUBECONFIG" ]; then
    echo "Error: mgmt_kubeconfig not found at ${MGMT_KUBECONFIG}"
    exit 1
fi

CLUSTER_NAME="$(cat ${SHARED_DIR}/cluster-name)"
if [ -z "$CLUSTER_NAME" ]; then
    echo "Error: cluster-name is empty"
    exit 1
fi

echo "Creating htpasswd file for cluster: ${CLUSTER_NAME}"
USER_PASSWORD=$(openssl rand -base64 16)
echo "user1:${USER_PASSWORD}" > "${SHARED_DIR}/users"
echo "$USER_PASSWORD" | htpasswd -c -B -i "${SHARED_DIR}/users.htpasswd" user1
for x in {2..5}; do
	USER_PASSWORD=$(openssl rand -base64 16)
	echo "user${x}:${USER_PASSWORD}" >> "${SHARED_DIR}/users"
	echo "$USER_PASSWORD" | htpasswd -B -i "${SHARED_DIR}/users.htpasswd" user$x
done
echo "Creating htpasswd secret: htpasswd-${CLUSTER_NAME} in namespace: clusters"
oc --kubeconfig=${MGMT_KUBECONFIG} -n clusters create secret generic htpasswd-${CLUSTER_NAME} --from-file=htpasswd="${SHARED_DIR}/users.htpasswd"
oc --kubeconfig=${MGMT_KUBECONFIG} -n clusters create secret generic htpasswd-plain-${CLUSTER_NAME} --from-file=credentials="${SHARED_DIR}/users"

echo "Patching hostedcluster to enable htpasswd OAuth provider"
cat > /tmp/oauth_patch.yaml <<EOF
spec:
  configuration:
    oauth:
      identityProviders:
      - htpasswd:
          fileData:
            name: htpasswd-${CLUSTER_NAME}
        mappingMethod: claim
        name: htpasswd
        type: HTPasswd
EOF

oc --kubeconfig=${MGMT_KUBECONFIG} patch hostedcluster -n clusters ${CLUSTER_NAME} --type=merge --patch-file=/tmp/oauth_patch.yaml

# Get hosted cluster API endpoint and kubeconfig
echo "Retrieving hosted cluster kubeconfig"
HOSTED_KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
if [ ! -f "$HOSTED_KUBECONFIG" ]; then
    echo "Error: nested_kubeconfig not found at ${HOSTED_KUBECONFIG}"
    exit 1
fi

# Wait for OAuth to be ready by attempting login
echo "Waiting for OAuth to be ready (attempting login with user1)"
auth_ready=false
count=0

while [[ $count -lt 40 ]]; do
	if cat "${SHARED_DIR}/users" | head -n1 | cut -d: -f2 | oc --kubeconfig="$HOSTED_KUBECONFIG" login --username=user1 &>/dev/null; then
        auth_ready=true
        echo "Successfully logged in with htpasswd credentials after $(( 15 * $count )) seconds"
        break
    else
        echo "Login attempt failed, waiting 15s... elapsed: $(( 15 * $count )) seconds"
        sleep 15s
        count=$(( count + 1 ))
    fi
done

if [[ $auth_ready == "false" ]]; then
    echo "Error: Unable to login with htpasswd credentials after 10 minutes"
    exit 1
fi

echo "htpasswd OAuth provider configured and verified successfully for ${CLUSTER_NAME}"
