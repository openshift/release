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

function configure_cluster_pull_secret () {
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

function create_catalog () {
    echo "Creating a custom catalog source using image: '$CATSRC_IMG'..."
    oc apply -f - << EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CS_CATSRC_NAME
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: $CATSRC_IMG
EOF
}

# Applicable for 'disconnected' env
function check_mirror_registry () {
    if test -s "${SHARED_DIR}/mirror_registry_url" ; then
        MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
        export MIRROR_REGISTRY_HOST
        echo "Using mirror registry: ${MIRROR_REGISTRY_HOST}"
    else
        echo "This is not a disconnected environment as no mirror registry url set. Skipping rest of steps..."
        exit 0
    fi
}

# Applicable for 'disconnected' env
function configure_host_pull_secret () {
    echo "Retrieving the redhat, redhat stage, and mirror registries pull secrets from shared credentials..."
    redhat_registry_path="/var/run/vault/mirror-registry/registry_redhat.json"
    redhat_auth_user=$(jq -r '.user' $redhat_registry_path)
    redhat_auth_password=$(jq -r '.password' $redhat_registry_path)
    redhat_registry_auth=$(echo -n " " "$redhat_auth_user":"$redhat_auth_password" | base64 -w 0)

    stage_registry_path="/var/run/vault/mirror-registry/registry_stage.json"
    stage_auth_user=$(jq -r '.user' $stage_registry_path)
    stage_auth_password=$(jq -r '.password' $stage_registry_path)
    stage_registry_auth=$(echo -n " " "$stage_auth_user":"$stage_auth_password" | base64 -w 0)

    mirror_registry_path="/var/run/vault/mirror-registry/registry_creds"
    mirror_registry_auth=$(head -n 1 "$mirror_registry_path" | base64 -w 0)
    
    echo "Appending the pull secrets to Podman auth configuration file '${XDG_RUNTIME_DIR}/containers/auth.json'..."
    oc extract secret/pull-secret -n openshift-config --confirm --to ${TMP_DIR}
    jq --argjson a "{\"registry.redhat.io\": {\"auth\": \"$redhat_registry_auth\"}, \"registry.stage.redhat.io\": {\"auth\": \"$stage_registry_auth\"}, \"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$mirror_registry_auth\"}}" '.auths |= . + $a' "${TMP_DIR}/.dockerconfigjson" > ${XDG_RUNTIME_DIR}/containers/auth.json
}

# Applicable for 'disconnected' env
function install_oc_mirror () {
    echo "[$(timestamp)] Installing the latest oc-mirror client..."
    run_command "curl -k -L -o oc-mirror.tar.gz https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/latest/oc-mirror.tar.gz"
    run_command "tar -xvzf oc-mirror.tar.gz && chmod +x ./oc-mirror && rm -f oc-mirror.tar.gz"
}

# Applicable for 'disconnected' env
function mirror_catalog_and_operator() {
    echo "[$(timestamp)] Creaing ImageSetConfiguration for catalog and operator related images..."
    cat > ${TMP_DIR}/imageset.yaml << EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  operators:
  - catalog: ${CATSRC_IMG}
    packages:
    - name: job-set
EOF

    echo "[$(timestamp)] Mirroring the images to the mirror registry..."
    run_command "./oc-mirror --v2 --config=${TMP_DIR}/imageset.yaml --workspace=file://${TMP_DIR} docker://${MIRROR_REGISTRY_HOST} --log-level=info --retry-times=5 --src-tls-verify=false --dest-tls-verify=false"

    echo "[$(timestamp)] Replacing the generated catalog source name with the ENV var '$CS_CATSRC_NAME'..."
    run_command "curl -k -L -o yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/') && chmod +x ./yq"
    run_command "./yq eval '.metadata.name = \"$CS_CATSRC_NAME\"' -i ${OC_MIRROR_OUTPUT_DIR}/cs-*.yaml"
    if [ -f "${OC_MIRROR_OUTPUT_DIR}/idms-oc-mirror.yaml" ] ; then
        echo "[$(timestamp)] Replacing the generated idms name with the ENV var '$IDMS_NAME'..."
        run_command "./yq eval '.metadata.name = \"$IDMS_NAME\"' -i ${OC_MIRROR_OUTPUT_DIR}/idms-*.yaml"
    else
        echo "No idms file found. Skipping replase ..."
    fi


    if [ -f "${OC_MIRROR_OUTPUT_DIR}/itms-oc-mirror.yaml" ] ; then
        echo "[$(timestamp)] Replacing the generated itms name with the ENV var '$ITMS_NAME'..."
        run_command "./yq eval '.metadata.name = \"$ITMS_NAME\"' -i ${OC_MIRROR_OUTPUT_DIR}/itms-*.yaml"
    else 
        echo "No itms file found. Skipping replase ..."
    fi


    echo "[$(timestamp)] Checking and applying the generated resource files..."
    run_command "find ${OC_MIRROR_OUTPUT_DIR} -type f | xargs -I{} bash -c 'cat {}; echo \"---\"'"
    run_command "oc apply -f ${OC_MIRROR_OUTPUT_DIR}"

    echo "[$(timestamp)] Waiting for the MachineConfigPool to finish rollout..."
    oc wait mcp --all --for=condition=Updating --timeout=5m || true
    oc wait mcp --all --for=condition=Updated --timeout=20m || true
    echo "[$(timestamp)] Rollout progress completed"
}

# Applicable for 'disconnected' env
# Note: This is a temporary workaround to avoid the disruptive impact of the 'enable-qe-catalogsource-disconnected' step.
# As per current implementation, that step is called by every 'disconnected' cluster provisioning workflow that maintained by QE.
# Hence this function can be removed in future once above mentioned design is well refined.
function tmp_prune_distruptive_resource() {
    echo "Pruning the disruptive resources in pervious step 'enable-qe-catalogsource-disconnected'..."
    run_command "oc delete catalogsource qe-app-registry -n openshift-marketplace --ignore-not-found"
    run_command "oc delete imagecontentsourcepolicy image-policy-aosqe --ignore-not-found"
    run_command "oc delete imagedigestmirrorset image-policy-aosqe --ignore-not-found"

    echo "[$(timestamp)] Waiting for the MachineConfigPool to finish rollout..."
    oc wait mcp --all --for=condition=Updating --timeout=5m || true
    oc wait mcp --all --for=condition=Updated --timeout=20m || true
    echo "[$(timestamp)] Rollout progress completed"
}

function check_catalog_readiness () {
    echo "Waiting the applied catalog source to become READY..."
    if wait_for_state "catalogsource/${CS_CATSRC_NAME}" "jsonpath={.status.connectionState.lastObservedState}=READY" "5m" "openshift-marketplace"; then
        echo "CatalogSource is ready"
    else
        echo "Timed out after 5m. Dumping resources for debugging..."
        run_command "oc get pod -n openshift-marketplace"
        run_command "oc get event -n openshift-marketplace | grep ${CS_CATSRC_NAME}"
        exit 1
    fi

    echo "Storing the catalog source name to '${SHARED_DIR}/jobset_catsrc_name'..."
    echo "${CS_CATSRC_NAME}" > "${SHARED_DIR}"/jobset_catsrc_name
}

if [ -z "${CATSRC_IMG}" ]; then
    echo "'CATSRC_IMG' is empty. Skipping catalog source creation..."
    exit 0
fi

timestamp
set_proxy

if [ "${MIRROR_OPERATORS}" == "true" ]; then
    export TMP_DIR=/tmp/mirror-jobset
    export OC_MIRROR_OUTPUT_DIR="${TMP_DIR}/working-dir/cluster-resources"
    export XDG_RUNTIME_DIR="${TMP_DIR}/run"
    mkdir -p "${XDG_RUNTIME_DIR}/containers"
    cd "$TMP_DIR"

    check_mirror_registry
    tmp_prune_distruptive_resource
    configure_host_pull_secret
    install_oc_mirror
    mirror_catalog_and_operator
else
    configure_cluster_pull_secret
    create_catalog
fi

check_catalog_readiness
echo "[$(timestamp)] Succeeded in creating the catalog source!"
