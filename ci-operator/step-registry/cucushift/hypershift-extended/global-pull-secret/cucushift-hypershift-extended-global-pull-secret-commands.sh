#!/bin/bash
set -xeuo pipefail

if [[ ${DYNAMIC_GLOBAL_PULL_SECRET_ENABLED} == "false" ]]; then
  echo "SKIP global pull secret checking ....."
  exit 0
fi

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Get hosted cluster endpoint
if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
    exit 1
fi
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"

if [ ! -f "$SHARED_DIR/image_registry.ini" ]; then
    echo "No image registry configured"
    exit 1
fi

DS_NAME="test-ds"
DS_NAMESPACE="test-ds-namespace"
IMAGE=$(cat "$SHARED_DIR/image_registry.ini" | grep "dst_image:" | cut -d ":" -f2- |tr -d " ")
REG_USER=$(cat "$SHARED_DIR/image_registry.ini" | grep "username:" | cut -d ":" -f2- |tr -d " ")
REG_PASS=$(cat "$SHARED_DIR/image_registry.ini" | grep "password:" | cut -d ":" -f2- |tr -d " ")
REG_ROUTE=$(cat "$SHARED_DIR/image_registry.ini" | grep "route:" | cut -d ":" -f2- |tr -d " ")

# retry_until_success <retries> <sleep_time> <function_name> [args...]
# - retries       : max number of attempts
# - sleep_time    : seconds between attempts
# - func          : the function to be called or a sub shell call
function retry_until_success() {
    local retries="$1"
    local sleep_time="$2"
    shift 2   # drop retries and sleep_time
    for i in $(seq 1 "$retries"); do
        echo "Attempt $i/$retries: running $*"
        if "$@"; then
            echo "Success on attempt $i"
            return 0
        fi
        echo "Failed attempt $i, retrying in $sleep_time seconds..."
        sleep "$sleep_time"
    done
    echo "$* did not succeed after $retries attempts"
    return 1
}

function check_pods_running() {
    pods=$(oc get pods -l app=${DS_NAME} -n ${DS_NAMESPACE} -o jsonpath='{.items[*].metadata.name}')
    for pod in $pods; do
        if ! oc get pod $pod -n ${DS_NAMESPACE} -o jsonpath='{.status.phase}'|grep Running; then
            return 1
        fi
    done
    return 0
}

# Check if the target auth exist in the global-pull-secret
function check_auth_exists_global_ps() {
  local auth="$1"
  global_ps=$(oc get --ignore-not-found secret global-pull-secret -n kube-system -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
  if [ -z "$global_ps" ]; then
      echo "global-pull-secret does not exist"
      return 1
  fi
  if ! jq --arg auth "$auth" -e '.auths[$auth]' <<< "$global_ps" >/dev/null; then
      echo "Auth: $auth does not exist in the global-pull-secret"
      return 1
  fi
  return 0
}

# Check if the target auth exist in the node
# node   : the node name
# auth   : the auth url in the /var/lib/kubelet/config.json
function check_auth_exists_ps_node() {
  local node="$1"
  local auth="$2"
  echo "Checking the /var/lib/kubelet/config.json file in node $node for authentication information..."
  secret_json=$(oc debug "node/$node" -q -- chroot /host cat /var/lib/kubelet/config.json)
  if ! jq --arg auth "$auth" -e '.auths[$auth]' <<< "$secret_json" >/dev/null; then
    echo "$auth does not exist in the node: $node"
    return 1
  fi
  echo "$auth exists in the node: $node"
  return 0
}

# Check if the target auth does not exist in the node anymore
# node   : the node name
# auth   : the auth url in the /var/lib/kubelet/config.json
function check_auth_not_exists_ps_node() {
  ! check_auth_exists_ps_node "$@"
}

# make sure the namespace exists
oc get namespace "$DS_NAMESPACE" &>/dev/null || oc create namespace "${DS_NAMESPACE}"
trap 'oc delete namespace "$DS_NAMESPACE"' EXIT

# create the test daemonset
cat <<EOF | oc apply -f -
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: "${DS_NAME}"
  namespace: ${DS_NAMESPACE}
spec:
  selector:
    matchLabels:
      app: "${DS_NAME}"
  template:
    metadata:
      labels:
        app: "${DS_NAME}"
    spec:
      terminationGracePeriodSeconds: 10
      containers:
        - name: "${DS_NAME}"
          image: ${IMAGE}
          command: ["sleep",  "30m"]
          imagePullPolicy: Always
EOF

# Check that all pods have authentication failures
pods=$(oc get pods -l app=${DS_NAME} -n ${DS_NAMESPACE} -o jsonpath='{.items[*].metadata.name}')
for pod in $pods; do
  echo "Checking pod $pod for authentication failure message..."
  retry_until_success 10 5  bash -c "oc get event --ignore-not-found -n ${DS_NAMESPACE} --field-selector involvedObject.name=$pod,involvedObject.kind=Pod -ojsonpath='{range .items[?(@.reason==\"Failed\")]}{.message}{\"\n\"}{end}' 2>&1 | grep -q 'authentication required'"
done
echo "All pods have the expected authentication failure message."

set +x

# create additional-pull-secret with reg auth, user, pass
oc get secret additional-pull-secret -n kube-system &>/dev/null || oc create secret docker-registry additional-pull-secret -n kube-system "--docker-server=$REG_ROUTE" "--docker-username=$REG_USER" "--docker-password=$REG_PASS"

# there is a global-pull-secret in kube-system now, which has the reg auth
retry_until_success 10 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system -o jsonpath='{.metadata.name}' | grep global-pull-secret"

# all pods should work now
retry_until_success 20 5 check_pods_running

# check that the reg auth is in the global-pull-secret
check_auth_exists_global_ps "$REG_ROUTE"

# in all nodes, the /var/lib/kubelet/config.json file should contain reg auth
nodes=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')
for node in $nodes; do
  check_auth_exists_ps_node "$node" "$REG_ROUTE"
done

set -x
# add a new auth into additional-pull-secret
new_auth_test_url="test-new-auth-global-ps"
new_auth_test_user="global-ps-user"
new_auth_test_pass="global-ps-pass"
auth_base64="$(echo \"$new_auth_test_user:$new_auth_test_pass\"|base64 -w0)"
nest_auth="{\"username\": \"$new_auth_test_user\", \"password\": \"$new_auth_test_pass\", \"auth\": \"$auth_base64\"}"
additional_ps=$(oc get --ignore-not-found secret additional-pull-secret -n kube-system -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
new_auths="$(echo $additional_ps | jq --arg auth_url $new_auth_test_url --argjson nest_auth "$nest_auth"  '.auths[$auth_url] = $nest_auth')"
new_auths_b64="$(echo $new_auths | jq -c '.' | base64 -w0)"
oc patch secret additional-pull-secret -n kube-system --type='merge' -p "{\"data\": {\".dockerconfigjson\": \"$new_auths_b64\"}}"

set +x
# the new auth will be synced to global-pull-secret
retry_until_success 10 5 check_auth_exists_global_ps "$new_auth_test_url"

# the new auth will be synced to all nodes
for node in $nodes; do
  retry_until_success 10 5 check_auth_exists_ps_node "$node" "$new_auth_test_url"
done

# delete the global-pull-secret, it will get created again
oc delete secret global-pull-secret -n kube-system
retry_until_success 10 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system -o jsonpath={.metadata.name} | grep global-pull-secret"

# delete the additional-pull-secret, all will be deleted
oc delete secret additional-pull-secret -n kube-system
retry_until_success 10 5 bash -c "oc get --ignore-not-found secret global-pull-secret -n kube-system --no-headers | grep -q '^' || echo \"0\""

# in each node, there is no more auth added here.
for node in $nodes; do
  retry_until_success 10 5 check_auth_not_exists_ps_node "$node" "$REG_ROUTE"
  retry_until_success 10 5 check_auth_not_exists_ps_node "$node" "$new_auth_test_url"
done
