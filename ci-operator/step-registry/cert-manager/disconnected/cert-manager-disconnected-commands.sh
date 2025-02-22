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

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "Setting proxy configuration..."
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "No proxy settings found. Skipping proxy configuration..."
    fi
}

function check_mirror_registry () {
    if test -s "${SHARED_DIR}/mirror_registry_url" ; then
        export MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
        echo "Using mirror registry: ${MIRROR_REGISTRY_HOST}"
    else
        echo "This is not a disconnected environment as no mirror registry url found. Skipping rest of steps..."
        exit 0
    fi
}

function prepare_pull_secret () {
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

function install_oc_mirror () {
    echo "Installing the latest oc-mirror client..."
    run_command "curl -k -L -o oc-mirror.tar.gz https://mirror.openshift.com/pub/openshift-v4/$(uname -m)/clients/ocp/latest/oc-mirror.tar.gz"
    run_command "tar -xvzf oc-mirror.tar.gz && chmod +x ./oc-mirror && rm -f oc-mirror.tar.gz"
    run_command "./oc-mirror version --output=yaml"
}

function mirror_catalog_and_operator() {
    echo "Listing available packages in the given index image '${INDEX_IMG}'..."
    ./oc-mirror list operators --catalog=${INDEX_IMG} --package=openshift-cert-manager-operator

    echo "Creaing ImageSetConfiguration for catalog and operator related images..."
    cat > ${TMP_DIR}/imageset.yaml << EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  operators:
  - catalog: ${INDEX_IMG}
    packages:
    - name: openshift-cert-manager-operator
  additionalImages: # (TEMP) images that will be used during E2E testing runtime
  - name: docker.io/alpine/helm:latest
  - name: docker.io/hashicorp/vault:latest
EOF

    echo "Mirroring the images to the mirror registry..."
    run_command "./oc-mirror --v2 --config=${TMP_DIR}/imageset.yaml --workspace=file://${TMP_DIR} docker://${MIRROR_REGISTRY_HOST} --loglevel=debug --src-tls-verify=false --dest-tls-verify=false"

    echo "Replacing the generated catalog source name with the ENV var '$CATSRC'..."
    run_command "curl -k -L -o yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/') && chmod +x ./yq"
    run_command "./yq eval '.metadata.name = \"$CATSRC\"' -i ${OC_MIRROR_OUTPUT_DIR}/cs-*.yaml"

    echo "Checking and applying the generated resource files..."
    run_command "find ${OC_MIRROR_OUTPUT_DIR} -type f -exec cat {} \;"
    run_command "oc apply -f ${OC_MIRROR_OUTPUT_DIR}"

    echo "Waiting the applied catalog source to become READY..."
    if wait_for_state "catalogsource/${CATSRC}" "jsonpath={.status.connectionState.lastObservedState}=READY" "5m" "openshift-marketplace"; then
        echo "CatalogSource is ready"
    else
        echo "Timed out after 5m. Dumping resources for debugging..."
        run_command "oc get pod -n openshift-marketplace"
        run_command "oc get event -n openshift-marketplace | grep ${CATSRC}"
        exit 1
    fi
}

timestamp
set_proxy
check_mirror_registry

export CATALOGSOURCE_NAME="cert-manager-disconnected-mirror"
export TMP_DIR=/tmp/disconnected
export OC_MIRROR_OUTPUT_DIR="${TMP_DIR}/working-dir/cluster-resources"
export XDG_RUNTIME_DIR="${TMP_DIR}/run"
mkdir -p "${XDG_RUNTIME_DIR}/containers"
cd "$TMP_DIR"

export CATSRC=redhat-operators-mirror

prepare_pull_secret
install_oc_mirror
mirror_catalog_and_operator

echo "[$(timestamp)] Succeeded in mirroring the cert-manager Operator for Red Hat OpenShift!"

# (TEMP) set ISCP for 'registry.connect.redhat.com/hashicorp/vault' and 'alpine/helm'
cat << EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: icsp-adhoc-testing
spec:
  repositoryDigestMirrors:
  - mirrors:
    - ${MIRROR_REGISTRY_HOST}/hashicorp/vault
    source: registry.connect.redhat.com/hashicorp/vault
  - mirrors:
    - ${MIRROR_REGISTRY_HOST}/hashicorp
    source: registry.connect.redhat.com/hashicorp
  - mirrors:
    - ${MIRROR_REGISTRY_HOST}/alpine/helm
    source: alpine/helm
  - mirrors:
    - ${MIRROR_REGISTRY_HOST}/alpine/helm
    source: docker.io/alpine/helm
  - mirrors:
    - ${MIRROR_REGISTRY_HOST}/alpine
    source: alpine
  - mirrors:
    - ${MIRROR_REGISTRY_HOST}/alpine
    source: docker.io/alpine
EOF
