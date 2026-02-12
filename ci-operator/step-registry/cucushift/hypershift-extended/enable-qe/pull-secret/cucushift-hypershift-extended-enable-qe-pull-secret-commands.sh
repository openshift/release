#!/bin/bash

set -e
set -u
set -o pipefail

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

function check_node() {
    local node_number ready_number
    node_number=$(oc get node --no-headers | grep -cv STATUS)
    ready_number=$(oc get node --no-headers | awk '$2 == "Ready"' | wc -l)
    if (( node_number == ready_number )); then
        echo "All nodes status check PASSED"
        return 0
    else
        if (( ready_number == 0 )); then
            echo >&2 "No any ready node"
        else
            echo >&2 "We found failed node"
            oc get node --no-headers | awk '$2 != "Ready"'
        fi
        return 1
    fi
}

function check_pod() {
    echo "Show all pods status for reference/debug"
    oc get pods --all-namespaces
}

function health_check() {
    echo "Step #1: Check all cluster operators get stable and ready"
    timeout 900s bash <<EOT
until
  oc wait clusteroperators --all --for='condition=Available=True' --timeout=30s && \
  oc wait clusteroperators --all --for='condition=Progressing=False' --timeout=30s && \
  oc wait clusteroperators --all --for='condition=Degraded=False' --timeout=30s;
do
  sleep 30 && echo "Cluster Operators Degraded=True,Progressing=True,or Available=False";
done
EOT
    oc wait clusterversion/version --for='condition=Available=True' --timeout=15m

    echo "Step #2: Make sure every machine is in 'Ready' status"
    retry_until_success 60 10 check_node

    echo "Step #3: Check all pods are in status running or complete"
    check_pod
}

# Function to check if an update of the pull-secret is required for HostedCluster NodePool
function check_update_pullsecret() {
    UPDATED_COUNT=0
    workers=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{","}{end}')
    IFS="," read -r -a workers_arr <<< "$workers"
    COUNT=${#workers_arr[*]}

    for worker in "${workers_arr[@]}"; do
        count=$(oc debug -n kube-system node/${worker} -- chroot /host/ bash -c 'cat /var/lib/kubelet/config.json' | grep -c quay.io/openshifttest || true)
        if [ $count -gt 0 ] ; then
            UPDATED_COUNT=$((UPDATED_COUNT + 1))
        fi
    done

    if [ "$UPDATED_COUNT" == "$COUNT" ] ; then
        echo "don't need to update HostedCluster NodePool's pull-secret"
        exit 0
    fi
}

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ $SKIP_HYPERSHIFT_PULL_SECRET_UPDATE == "true" ]]; then
  echo "SKIP ....."
  exit 0
fi

if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
  exit 1
fi

export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
check_update_pullsecret

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
CLUSTER_NAME=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" -o=jsonpath='{.items[0].metadata.name}')
echo $CLUSTER_NAME

secret_name=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" "$CLUSTER_NAME" -ojsonpath="{.spec.pullSecret.name}")
oc get secret "$secret_name" -n "$HYPERSHIFT_NAMESPACE" -o json | jq -r '.data.".dockerconfigjson"' | base64 -d > /tmp/global-pull-secret.json

optional_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.user')
optional_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.password')
qe_registry_auth=`echo -n "${optional_auth_user}:${optional_auth_password}" | base64 -w 0`

openshifttest_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.user')
openshifttest_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.password')
openshifttest_registry_auth=`echo -n "${openshifttest_auth_user}:${openshifttest_auth_password}" | base64 -w 0`

stage_auth_user=$(cat "/var/run/vault/mirror-registry/registry_stage.json" | jq -r '.user')
stage_auth_password=$(cat "/var/run/vault/mirror-registry/registry_stage.json" | jq -r '.password')
stage_registry_auth=`echo -n "${stage_auth_user}:${stage_auth_password}" | base64 -w 0`

reg_brew_user=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.user')
reg_brew_password=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.password')
brew_registry_auth=`echo -n "${reg_brew_user}:${reg_brew_password}" | base64 -w 0`
jq --argjson a "{\"brew.registry.redhat.io\": {\"auth\": \"${brew_registry_auth}\"},\"quay.io/openshift-qe-optional-operators\": {\"auth\": \"${qe_registry_auth}\"},\"quay.io/openshifttest\": {\"auth\": \"${openshifttest_registry_auth}\"},\"registry.stage.redhat.io\": {\"auth\": \"$stage_registry_auth\"}}" '.auths |= . + $a' "/tmp/global-pull-secret.json" > /tmp/global-pull-secret.json.tmp

mv /tmp/global-pull-secret.json.tmp /tmp/global-pull-secret.json
oc create secret -n "$HYPERSHIFT_NAMESPACE" generic "$CLUSTER_NAME"-pull-secret-new --from-file=.dockerconfigjson=/tmp/global-pull-secret.json
rm /tmp/global-pull-secret.json

echo "{\"spec\":{\"pullSecret\":{\"name\":\"$CLUSTER_NAME-pull-secret-new\"}}}" > /tmp/patch.json
oc patch hostedclusters -n "$HYPERSHIFT_NAMESPACE" "$CLUSTER_NAME" --type=merge -p="$(cat /tmp/patch.json)"

echo "check day-2 pull-secret update"
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
RETRIES=45
for i in $(seq ${RETRIES}); do
  UPDATED_COUNT=0
  workers=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{","}{end}')
  IFS="," read -r -a workers_arr <<< "$workers"
  COUNT=${#workers_arr[*]}
  for worker in "${workers_arr[@]}"
  do
  count=$(oc debug -n kube-system node/${worker} -- chroot /host/ bash -c 'cat /var/lib/kubelet/config.json' | grep -c quay.io/openshifttest || true)
  if [ $count -gt 0 ] ; then
      UPDATED_COUNT=`expr $UPDATED_COUNT + 1`
  fi
  done
  if [ "$UPDATED_COUNT" == "$COUNT" ] ; then
      echo "day 2 pull-secret successful"
      health_check
      exit 0
  fi
  echo "Try ${i}/${RETRIES}: pull-secret is not updated yet. Checking again in 60 seconds"
  sleep 60
done
echo "day 2 pull-secret update error"
exit 1
