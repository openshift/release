#!/bin/bash

set -e
set -u
set -o pipefail

CATALOGSOURCE_NAME="qe-app-registry"
ICSP_NAME="stage-registry"
IDMS_NAME="stage-registry-idms"
ART_SECRET_PATH="/var/run/vault/deploy-konflux-operator-art-image-share/.dockerconfigjson"
STAGE_REGISTRY_PATH="/var/run/vault/mirror-registry/registry_stage.json"

function set_proxy() {
    if test -s "${SHARED_DIR}/proxy-conf.sh"; then
        echo "setting the proxy"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function get_ocp_version() {
    OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
    OCP_MAJOR_MINOR=$(echo "${OCP_VERSION}" | cut -d '.' -f1,2)
    OCP_MINOR=$(echo "${OCP_VERSION}" | cut -d '.' -f2)
    echo "Detected OCP version: ${OCP_VERSION} (${OCP_MAJOR_MINOR}, minor=${OCP_MINOR})"
}

function check_olm_capability() {
    knownCaps=$(oc get clusterversion version -o=jsonpath="{.status.capabilities.knownCapabilities}")
    if [[ ${knownCaps} =~ "OperatorLifecycleManager\"," ]]; then
        echo "knownCapabilities contains OperatorLifecycleManagerv0"
        enabledCaps=$(oc get clusterversion version -o=jsonpath="{.status.capabilities.enabledCapabilities}")
        if [[ ! ${enabledCaps} =~ "OperatorLifecycleManager\"," ]]; then
            echo "OperatorLifecycleManagerv0 capability is not enabled, skipping stage catalogsource setup..."
            exit 0
        fi
    fi
}

function check_mcp_status() {
    machineCount=$(oc get mcp worker -o=jsonpath='{.status.machineCount}')
    COUNTER=0
    while [ $COUNTER -lt 1200 ]; do
        sleep 20
        COUNTER=$((COUNTER + 20))
        echo "waiting ${COUNTER}s for MCP rollout"
        updatedMachineCount=$(oc get mcp worker -o=jsonpath='{.status.updatedMachineCount}')
        if [[ "${updatedMachineCount}" == "${machineCount}" ]]; then
            echo "MCP updated successfully"
            break
        fi
    done
    if [[ "${updatedMachineCount}" != "${machineCount}" ]]; then
        echo "MCP rollout timed out"
        run_command "oc get mcp,node"
        run_command "oc get mcp worker -o yaml"
        return 1
    fi
}

function update_global_auth() {
    run_command "oc extract secret/pull-secret -n openshift-config --confirm --to /tmp"; ret=$?
    if [[ $ret -ne 0 ]]; then
        echo "!!! fail to get the cluster global auth."
        return 1
    fi

    if [[ ! -f "${ART_SECRET_PATH}" ]]; then
        echo "!!! quay.io/openshift-art credentials not found at ${ART_SECRET_PATH}"
        return 1
    fi

    new_dockerconfig="/tmp/new-dockerconfigjson"
    art_auths=$(jq -r '.auths' "${ART_SECRET_PATH}")

    if [[ -f "${STAGE_REGISTRY_PATH}" ]]; then
        echo "Merging registry.stage.redhat.io credentials..."
        stage_auth_user=$(jq -r '.user' "${STAGE_REGISTRY_PATH}")
        stage_auth_password=$(jq -r '.password' "${STAGE_REGISTRY_PATH}")
        stage_registry_auth=$(echo -n "${stage_auth_user}:${stage_auth_password}" | base64 -w 0)
        jq --argjson art "${art_auths}" \
           --argjson stage "{\"registry.stage.redhat.io\": {\"auth\": \"${stage_registry_auth}\"}}" \
           '.auths |= . + $art + $stage' "/tmp/.dockerconfigjson" > "${new_dockerconfig}"
    else
        echo "WARNING: stage registry credentials not found at ${STAGE_REGISTRY_PATH}, merging only ART credentials"
        jq --argjson art "${art_auths}" '.auths |= . + $art' "/tmp/.dockerconfigjson" > "${new_dockerconfig}"
    fi

    ret=0
    run_command "oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=${new_dockerconfig}" || ret=$?
    if [[ $ret -eq 0 ]]; then
        check_mcp_status
        echo "update the cluster global auth successfully."
    else
        echo "!!! fail to update pull-secret, retry and enable log..."
        sleep 1
        ret=0
        run_command "oc --loglevel=10 set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=${new_dockerconfig}" || ret=$?
        if [[ $ret -eq 0 ]]; then
            echo "update the cluster global auth successfully after retry."
        else
            echo "!!! still fail to update pull-secret after retry"
            return 1
        fi
    fi
}

function create_mirror_policy() {
    if [[ ${OCP_MINOR} -le 12 ]]; then
        echo "OCP 4.12 or earlier — creating ImageContentSourcePolicy"
        cat <<EOF | oc apply -f -
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: ${ICSP_NAME}
spec:
  repositoryDigestMirrors:
  - mirrors:
    - registry.stage.redhat.io
    source: registry.redhat.io
EOF
    else
        echo "OCP 4.13+ — creating ImageDigestMirrorSet"
        cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ${IDMS_NAME}
spec:
  imageDigestMirrors:
  - mirrors:
    - registry.stage.redhat.io
    source: registry.redhat.io
EOF
    fi

    if [ $? == 0 ]; then
        echo "create the mirror policy successfully"
    else
        echo "!!! fail to create the mirror policy"
        return 1
    fi
}

function check_marketplace() {
    ret=0
    run_command "oc get ns openshift-marketplace" || ret=$?
    if [[ $ret -eq 0 ]]; then
        echo "openshift-marketplace project AlreadyExists, skip creating."
        return 0
    fi

    cat <<EOF | oc create -f -
apiVersion: v1
kind: Namespace
metadata:
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
  name: openshift-marketplace
EOF
}

function create_catalog_source() {
    local index_image="quay.io/openshift-art/stage-fbc-fragments:ocp-${OCP_MAJOR_MINOR}"

    echo "Removing existing ${CATALOGSOURCE_NAME} catalogsource if present..."
    oc delete catalogsource "${CATALOGSOURCE_NAME}" -n openshift-marketplace --ignore-not-found=true
    oc wait --for=delete "catalogsource/${CATALOGSOURCE_NAME}" -n openshift-marketplace --timeout=120s || true

    echo "Creating stage FBC catalogsource: ${CATALOGSOURCE_NAME}"
    echo "Using index image: ${index_image}"

    if [[ ${OCP_MINOR} -ge 15 ]]; then
        echo "OCP 4.15+ — using FBC format with grpcPodConfig.extractContent"
        cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOGSOURCE_NAME}
  namespace: openshift-marketplace
spec:
  displayName: Stage FBC Operators
  grpcPodConfig:
    extractContent:
      cacheDir: /tmp/cache
      catalogDir: /configs
    memoryTarget: 30Mi
  image: ${index_image}
  publisher: OpenShift QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
    else
        echo "OCP < 4.15 — using plain grpc CatalogSource"
        cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOGSOURCE_NAME}
  namespace: openshift-marketplace
spec:
  displayName: Stage FBC Operators
  image: ${index_image}
  publisher: OpenShift QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
    fi

    set +e
    COUNTER=0
    while [ $COUNTER -lt 600 ]; do
        sleep 20
        COUNTER=$((COUNTER + 20))
        echo "waiting ${COUNTER}s"
        STATUS=$(oc -n openshift-marketplace get catalogsource "${CATALOGSOURCE_NAME}" -o=jsonpath="{.status.connectionState.lastObservedState}")
        if [[ "${STATUS}" == "READY" ]]; then
            echo "create the stage FBC CatalogSource successfully"
            break
        fi
    done
    if [[ "${STATUS}" != "READY" ]]; then
        echo "!!! fail to create stage FBC CatalogSource"
        run_command "oc get pods -o wide -n openshift-marketplace"
        run_command "oc -n openshift-marketplace get catalogsource ${CATALOGSOURCE_NAME} -o yaml"
        run_command "oc -n openshift-marketplace get pods -l olm.catalogSource=${CATALOGSOURCE_NAME} -o yaml"
        node_name=$(oc -n openshift-marketplace get pods -l "olm.catalogSource=${CATALOGSOURCE_NAME}" -o=jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)
        if [[ -n "${node_name}" ]]; then
            run_command "oc create ns debug-qe -o yaml | oc label -f - security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite"
            run_command "oc -n debug-qe debug node/${node_name} -- chroot /host podman pull --authfile /var/lib/kubelet/config.json ${index_image}"
        fi
        run_command "oc get mcp,node"
        run_command "oc get mcp worker -o yaml"
        run_command "oc get mc \$(oc get mcp/worker --no-headers | awk '{print \$2}') -o=jsonpath={.spec.config.storage.files} | jq '.[] | select(.path==\"/var/lib/kubelet/config.json\")'"
        return 1
    fi
    set -e
}

set_proxy
run_command "oc whoami"
run_command "which oc && oc version -o yaml"

get_ocp_version
check_olm_capability
update_global_auth
create_mirror_policy
check_marketplace
create_catalog_source
