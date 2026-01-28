#! /bin/bash

set -e
set -u
set -o pipefail

test_version="${LOGGING_TEST_VERSION}"

if [[ -z ${test_version} ]] ; then
    echo "test_version is not set"
    exit 1
fi

ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null | cut -d. -f1-2)
if [[ -z "${ocp_version}" ]]; then
    echo "could not detect cluster version"
    exit 1
fi

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
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

function check_mcp_status() {
    machineCount=$(oc get mcp worker -o=jsonpath='{.status.machineCount}')
    COUNTER=0
    while [ $COUNTER -lt 1200 ]
    do
        sleep 20
        COUNTER=`expr $COUNTER + 20`
        echo "waiting ${COUNTER}s"
        updatedMachineCount=$(oc get mcp worker -o=jsonpath='{.status.updatedMachineCount}')
        if [[ ${updatedMachineCount} = "${machineCount}" ]]; then
            echo "MCP updated successfully"
            break
        fi
    done
    if [[ ${updatedMachineCount} != "${machineCount}" ]]; then
        run_command "oc get mcp,node"
        run_command "oc get mcp worker -o yaml"
        return 1
    fi
}

function update_global_auth () {
    # get the current global auth
    run_command "oc extract secret/pull-secret -n openshift-config --confirm --to /tmp"; ret=$?
    if [[ $ret -ne 0 ]]; then
        echo "!!! fail to get the cluster global auth."
        return 1
    fi

    # add quay.io/openshifttest auth to the global auth
    new_dockerconfig="/tmp/new-dockerconfigjson"
    openshifttest_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.user')
    openshifttest_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.password')
    openshifttest_registry_auth=`echo -n "${openshifttest_auth_user}:${openshifttest_auth_password}" | base64 -w 0`

    stage_auth_user=$(cat "/var/run/vault/mirror-registry/registry_stage.json" | jq -r '.user')
    stage_auth_password=$(cat "/var/run/vault/mirror-registry/registry_stage.json" | jq -r '.password')
    stage_registry_auth=`echo -n "${stage_auth_user}:${stage_auth_password}" | base64 -w 0`

    reg_brew_user=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.user')
    reg_brew_password=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.password')
    brew_registry_auth=`echo -n "${reg_brew_user}:${reg_brew_password}" | base64 -w 0`

    # Merge konflux operator art image share credentials if available
    konflux_dockerconfig="/var/run/vault/deploy-konflux-operator-art-image-share/.dockerconfigjson"
    if [[ -f "${konflux_dockerconfig}" ]]; then
      echo "Merging konflux operator art image share credentials..."
      # Extract auths from konflux dockerconfig and merge with other auths
      konflux_auths=$(cat "${konflux_dockerconfig}" | jq -r '.auths')
      jq --argjson a "{\"brew.registry.redhat.io\": {\"auth\": \"${brew_registry_auth}\"},\"quay.io/openshifttest\": {\"auth\": \"${openshifttest_registry_auth}\"},\"registry.stage.redhat.io\": {\"auth\": \"$stage_registry_auth\"}}" --argjson konflux "$konflux_auths" '.auths |= . + $a + $konflux' "/tmp/.dockerconfigjson" > ${new_dockerconfig}
    else
      echo "Konflux credentials not found at ${konflux_dockerconfig}, skipping..."
      jq --argjson a "{\"brew.registry.redhat.io\": {\"auth\": \"${brew_registry_auth}\"},\"quay.io/openshifttest\": {\"auth\": \"${openshifttest_registry_auth}\"},\"registry.stage.redhat.io\": {\"auth\": \"$stage_registry_auth\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" > ${new_dockerconfig}
    fi

    # run_command "cat ${new_dockerconfig} | jq"

    # update global auth
    ret=0
    run_command "oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=${new_dockerconfig}" || ret=$?
    if [[ $ret -eq 0 ]]; then
        check_mcp_status
        echo "update the cluster global auth successfully."
    else
        echo "!!! fail to add stage registry auth, retry and enable log..."
        sleep 1
        ret=0
        run_command "oc --loglevel=10 set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=${new_dockerconfig}" || ret=$?
        if [[ $ret -eq 0 ]]; then
            echo "update the cluster global auth successfully after retry."
        else
            echo "!!! still fail to add stage registry auth after retry"
            return 1
        fi
    fi
}


# create ICSP for connected env.
function create_icsp_connected () {
    run_command "oc delete imagecontentsourcepolicies.operator.openshift.io/brew-registry --ignore-not-found=true"
    cat <<EOF | oc apply -f -
    apiVersion: operator.openshift.io/v1alpha1
    kind: ImageContentSourcePolicy
    metadata:
        name: logging-registry
    spec:
        repositoryDigestMirrors:
        - mirrors:
          - registry.stage.redhat.io
          source: registry.redhat.io
EOF

    if [ $? == 0 ]; then
        echo "create the ICSP successfully"
        sleep 60
        echo "check mcp status"
        check_mcp_status
    else
        echo "!!! failed to create the ICSP"
        return 1
    fi
}

function create_catalog_source()
{
    local catalogsource_name="$1"
    local operator_name="$2"
    index_image="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:logging-${test_version}__v${ocp_version}__${operator_name}-rhel9-operator"

    # get cluster Major.Minor version
    kube_major=$(oc version -o json |jq -r '.serverVersion.major')
    kube_minor=$(oc version -o json |jq -r '.serverVersion.minor' | sed 's/+$//')

    echo "Create QE catalogsource: $catalogsource_name"
    echo "Use $index_image in catalogsource/$catalogsource_name"

    run_command "oc delete catsrc $catalogsource_name -n openshift-marketplace --ignore-not-found=true"
    # since OCP 4.15, the official catalogsource use this way. OCP4.14=K8s1.27
    # details: https://issues.redhat.com/browse/OCPBUGS-31427
    if [[ ${kube_major} -gt 1 || ${kube_minor} -gt 27 ]]; then
        echo "the index image as the initContainer cache image)"
        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $catalogsource_name
  namespace: openshift-marketplace
spec:
  displayName: Production Operators
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
        echo "the index image as the server image"
        cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $catalogsource_name
  namespace: openshift-marketplace
spec:
  displayName: Production Operators
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
    while [ $COUNTER -lt 600 ]
    do
        sleep 20
        COUNTER=`expr $COUNTER + 20`
        echo "waiting ${COUNTER}s"
        STATUS=`oc -n openshift-marketplace get catalogsource $catalogsource_name -o=jsonpath="{.status.connectionState.lastObservedState}"`
        if [[ $STATUS = "READY" ]]; then
            echo "create the QE CatalogSource successfully"
            break
        fi
    done
    if [[ $STATUS != "READY" ]]; then
        echo "!!! fail to create QE CatalogSource"
        run_command "oc get pods -o wide -n openshift-marketplace"
        run_command "oc -n openshift-marketplace get catalogsource $catalogsource_name -o yaml"
        run_command "oc -n openshift-marketplace get pods -l olm.catalogSource=$catalogsource_name -o yaml"
        node_name=$(oc -n openshift-marketplace get pods -l olm.catalogSource=$catalogsource_name -o=jsonpath='{.items[0].spec.nodeName}')
        run_command "oc create ns debug-qe -o yaml | oc label -f - security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite"
        run_command "oc -n debug-qe debug node/${node_name} -- chroot /host podman pull --authfile /var/lib/kubelet/config.json ${index_image}"

        run_command "oc get mcp,node"
        run_command "oc get mcp worker -o yaml"
        run_command "oc get mc $(oc get mcp/worker --no-headers | awk '{print $2}') -o=jsonpath={.spec.config.storage.files}|jq '.[] | select(.path==\"/var/lib/kubelet/config.json\")'"

        exit 1
    fi
    set -e
}

# From 4.11 on, the marketplace is optional.
# That means, once the marketplace disabled, its "openshift-marketplace" project will NOT be created as default.
# But, for OLM, its global namespace still is "openshift-marketplace"(details: https://bugzilla.redhat.com/show_bug.cgi?id=2076878),
# so we need to create it manually so that optional operator teams' test cases can be run smoothly.
function check_marketplace () {
    # caps=`oc get clusterversion version -o=jsonpath="{.status.capabilities.enabledCapabilities}"`
    # if [[ ${caps} =~ "marketplace" ]]; then
    #     echo "marketplace installed, skip..."
    #     return 0
    # fi
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

# from OCP 4.15, the OLM is optional, details: https://issues.redhat.com/browse/OCPVE-634
# since OCP4.18, OLMv1 is a new capability: OperatorLifecycleManagerV1
function check_olm_capability() {
    # check if OLMv0 capability is added
    knownCaps=$(oc get clusterversion version -o=jsonpath="{.status.capabilities.knownCapabilities}")
    if [[ ${knownCaps} =~ "OperatorLifecycleManager\"," ]]; then
        echo "knownCapabilities contains OperatorLifecycleManagerv0"
        # check if OLMv0 capability enabled
        enabledCaps=$(oc get clusterversion version -o=jsonpath="{.status.capabilities.enabledCapabilities}")
        if [[ ! ${enabledCaps} =~ "OperatorLifecycleManager\"," ]]; then
            echo "OperatorLifecycleManagerv0 capability is not enabled, skipping operator installation."
            return 1 # Return a non-zero exit code
        fi
    fi
    return 0 # Return 0 for success
}

set_proxy
# Check for required commands
command -v jq >/dev/null 2>&1 || { echo >&2 "Error: jq is not installed. Aborting."; exit 1; }
command -v yq-go >/dev/null 2>&1 || { echo >&2 "Error: yq-go is not installed. Aborting."; exit 1; }
run_command "which oc && oc version -o yaml"
run_command "oc whoami"
update_global_auth
sleep 5
create_icsp_connected

check_olm_capability
if [[ $? -ne 0 ]]; then
    echo "Skipping operator installation due to OLM capability."
    exit 1
fi

check_marketplace
# oc delete catsrc qe-app-registry -n openshift-marketplace || true
create_catalog_source "cluster-logging-operator-registry" "cluster-logging"
create_catalog_source "loki-operator-registry" "loki"

#support hypershift config guest cluster's icsp
oc get imagecontentsourcepolicy -oyaml > /tmp/mgmt_icsp.yaml && yq-go r /tmp/mgmt_icsp.yaml 'items[*].spec.repositoryDigestMirrors' -  | sed  '/---*/d' > ${SHARED_DIR}/mgmt_icsp.yaml
