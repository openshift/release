#!/bin/bash

set -e
set -u
set -o pipefail

function timestamp() {
    date -u --rfc-3339=seconds
}

function run_command() {
    local cmd="$1"
    echo "Running Command: ${cmd}"
    eval "${cmd}"
}

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "Setting proxy configuration..."
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "No proxy settings found. Skipping proxy configuration..."
    fi
}

function add_pull_secret () {
    echo "Retrieving the redhat stage pull secret from shared credentials..."
    stage_registry_path="/var/run/vault/mirror-registry/registry_stage.json"
    stage_auth_user=$(jq -r '.user' $stage_registry_path)
    stage_auth_password=$(jq -r '.password' $stage_registry_path)
    stage_registry_auth=$(echo -n " " "$stage_auth_user":"$stage_auth_password" | base64 -w 0)

    echo "Updating the image pull secret with the auth config..."
    oc extract secret/pull-secret -n openshift-config --confirm --to /tmp
    new_dockerconfig_path="/tmp/.new-dockerconfigjson"
    jq --argjson a "{\"registry.stage.redhat.io\": {\"auth\": \"$stage_registry_auth\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" >"$new_dockerconfig_path"
    oc set data secret pull-secret -n openshift-config --from-file=.dockerconfigjson=$new_dockerconfig_path
}

function wait_for_state() {
    local object="$1"
    local state="$2"
    local timeout="$3"
    local namespace="${4:-}"
    local selector="${5:-}"

    echo "Waiting for '${object}' in namespace '${namespace}' with selector '${selector}' to exist..."
    for _ in {1..30}; do
        oc get ${object} --selector="${selector}" -n=${namespace} |& grep -ivE "(no resources found|not found)" && break || sleep 5
    done

    echo "Waiting for '${object}' in namespace '${namespace}' with selector '${selector}' to become '${state}'..."
    oc wait --for=${state} --timeout=${timeout} ${object} --selector="${selector}" -n="${namespace}"
    return $?
}

function create_catalogsource () {
    echo "Creating a custom catalog source using image: '$INDEX_IMG'..."
    oc apply -f - << EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATSRC_NAME
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: $INDEX_IMG
EOF

    if wait_for_state "catalogsource/${CATSRC_NAME}" "jsonpath={.status.connectionState.lastObservedState}=READY" "5m" "openshift-marketplace"; then
        echo "CatalogSource is ready"
    else
        echo "Timed out after 5m. Dumping resources for debugging..."
        run_command "oc get pod -n openshift-marketplace"
        run_command "oc get event -n openshift-marketplace | grep ${CATSRC_NAME}"
        exit 1
    fi

    echo "Storing the catalog source name to '${SHARED_DIR}/catsrc_name'..."
    echo "${CATSRC_NAME}" > "${SHARED_DIR}"/catsrc_name
}

if [ -z "${INDEX_IMG}" ]; then
    echo "'INDEX_IMG' is empty. Skipping catalog source creation..."
    exit 0
fi

timestamp
set_proxy
add_pull_secret
create_catalogsource

echo "[$(timestamp)] Succeeded in creating the catalog source!"
