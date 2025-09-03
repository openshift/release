#! /bin/bash

set -e
set -u
set -o pipefail


index_image="${MULTISTAGE_PARAM_OVERRIDE_LOGGING_INDEX_IMAGE/registry-proxy.engineering.redhat.com/brew.registry.redhat.io}"
logging_bundles="${MULTISTAGE_PARAM_OVERRIDE_LOGGING_BUNDLES}"
test_version="${LOGGING_TEST_VERSION}"

if [[ -z ${logging_bundles} ]] && [[ -z ${index_image} ]]; then
    echo "logging_bundles and index_image are not set."
    exit 1
fi

if [[ -z ${test_version} ]] ; then
    echo "test_version is not set, can't create correct ICSP"
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

    jq --argjson a "{\"brew.registry.redhat.io\": {\"auth\": \"${brew_registry_auth}\"},\"quay.io/openshifttest\": {\"auth\": \"${openshifttest_registry_auth}\"},\"registry.stage.redhat.io\": {\"auth\": \"$stage_registry_auth\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" > ${new_dockerconfig}

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

    if [[ $index_image == "brew.registry.redhat.io/rh-osbs/iib"* ]] ; then
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
    else
        image_version="${test_version//./-}"
        cat <<EOF | oc apply -f -
        apiVersion: operator.openshift.io/v1alpha1
        kind: ImageContentSourcePolicy
        metadata:
          name: logging-registry
        spec:
          repositoryDigestMirrors:
          - source: registry.redhat.io/openshift-logging/cluster-logging-rhel9-operator
            mirrors:
            - quay.io/redhat-user-workloads/obs-logging-tenant/cluster-logging-operator-v$image_version
          - source: registry.redhat.io/openshift-logging/log-file-metric-exporter-rhel9
            mirrors:
            - quay.io/redhat-user-workloads/obs-logging-tenant/log-file-metric-exporter-v$image_version
          - source: registry.redhat.io/openshift-logging/eventrouter-rhel9
            mirrors:
            - quay.io/redhat-user-workloads/obs-logging-tenant/logging-eventrouter-v$image_version
          - source: registry.redhat.io/openshift-logging/vector-rhel9
            mirrors:
            - quay.io/redhat-user-workloads/obs-logging-tenant/logging-vector-v$image_version
          - source: registry.redhat.io/openshift-logging/cluster-logging-operator-bundle
            mirrors:
            - quay.io/redhat-user-workloads/obs-logging-tenant/cluster-logging-operator-bundle-v$image_version
          - source: registry.redhat.io/openshift-logging/loki-operator-bundle
            mirrors:
            - quay.io/redhat-user-workloads/obs-logging-tenant/loki-operator-bundle-v$image_version
          - source: registry.redhat.io/openshift-logging/loki-rhel9-operator
            mirrors:
            - quay.io/redhat-user-workloads/obs-logging-tenant/loki-operator-v$image_version
          - source: registry.redhat.io/openshift-logging/logging-loki-rhel9
            mirrors:
            - quay.io/redhat-user-workloads/obs-logging-tenant/logging-loki-v$image_version
          - source: registry.redhat.io/openshift-logging/lokistack-gateway-rhel9
            mirrors:
            - quay.io/redhat-user-workloads/obs-logging-tenant/lokistack-gateway-v$image_version
          - source: registry.redhat.io/openshift-logging/opa-openshift-rhel9
            mirrors:
            - quay.io/redhat-user-workloads/obs-logging-tenant/opa-openshift-v$image_version
EOF
    fi
    if [ $? == 0 ]; then
        echo "create the ICSP successfully"
    else
        echo "!!! fail to create the ICSP"
        return 1
    fi

}

function operator_sdk_install_operator() {
    local bundle="$1"
    local install_namespace="$2"

    echo "Install operator to namespace ${install_namespace} with bundle ${bundle}"

    cat << EOF | oc apply -f -
    apiVersion: v1
    kind: Namespace
    metadata:
      labels:
        openshift.io/cluster-monitoring: "true"
        pod-security.kubernetes.io/audit: privileged
        pod-security.kubernetes.io/audit-version: latest
        pod-security.kubernetes.io/enforce: privileged
        pod-security.kubernetes.io/enforce-version: latest
        pod-security.kubernetes.io/warn: privileged
        pod-security.kubernetes.io/warn-version: latest
        security.openshift.io/scc.podSecurityLabelSync: "false"
      name: $install_namespace
EOF

    local -i ret=0
    run_command "operator-sdk run bundle $bundle -n $install_namespace --timeout=5m" || ret=$?
    # sometimes the command fails, but the installation succeeds, here check the operator pod's status before failing the script
    if [ $ret -ne 0 ]; then
        sub=$(oc get sub -n $install_namespace -ojsonpath="{.items[].metadata.name}")
        if [[ -z $sub ]]; then
            echo "subscription is not created, installing operator failed"
            return 1
        else
            interval=30
            max_retries=10
            csv_name=""
            retry_count=0
            echo "Waiting for '$sub' installed CSV to be populated (max retries: $max_retries)..."
            while [[ -z "$csv_name" ]]; do
                if [[ "$retry_count" -ge "$max_retries" ]]; then
                    echo "Error: Maximum number of retries ($max_retries) exceeded. The installed CSV was not found."
                    return 1
                fi
                csv_name=$(oc -n $install_namespace get sub $sub -ojsonpath="{.status.installedCSV}" 2>/dev/null)
                if [[ -z "$csv_name" ]]; then
                    retry_count=$((retry_count + 1))
                    echo "Retry #$retry_count: No installed CSV found yet. Retrying in $interval seconds..."
                    sleep "$interval"
                fi
            done
            local -i exit_code=0
            run_command "oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/$csv_name -n $install_namespace --timeout=5m" || exit_code=$?
            if [ $exit_code -ne 0 ]; then
                echo "install operator failed"
                run_command "oc get ns $install_namespace -oyaml"
                echo
                run_command "oc get sub -n $install_namespace -oyaml"
                echo
                run_command "oc get pod -n $install_namespace -oyaml"
                echo
                run_command "oc get csv $csv_name -n $install_namespace -oyaml"
                echo
                run_command "oc get installplan -n $install_namespace -oyaml"
                return 1
            fi
        fi
    fi
}

function subscribe_operator() {
    local package_name="$1"
    local install_namespace="$2"

    echo "Subscribe operator $package_name to namespace $install_namespace"

    echo "Create namespace $install_namespace"
    cat << EOF | oc apply -f -
    apiVersion: v1
    kind: Namespace
    metadata:
        labels:
            openshift.io/cluster-monitoring: "true"
        name: $install_namespace
EOF

    echo "Create operator group"
    cat << EOF | oc apply -f -
    apiVersion: operators.coreos.com/v1
    kind: OperatorGroup
    metadata:
        name: $install_namespace
        namespace: $install_namespace
    spec: {}
EOF

    echo "Create subscription"
    cat << EOF | oc apply -f -
    apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
        name: $package_name
        namespace: $install_namespace
    spec:
        channel: stable-${test_version}
        installPlanApproval: Automatic
        name: $package_name
        source: $CATALOGSOURCE_NAME
        sourceNamespace: openshift-marketplace
EOF

    # Need to allow some time before checking if the operator is installed.
    sleep 60

    RETRIES=30
    CSV=
    for i in $(seq "${RETRIES}"); do
        if [[ -z "${CSV}" ]]; then
            CSV=$(oc get subscription -n "${install_namespace}" "${package_name}" -o jsonpath='{.status.installedCSV}')
        fi

        if [[ -z "${CSV}" ]]; then
            echo "Try ${i}/${RETRIES}: can't get the ${package_name} yet. Checking again in 30 seconds"
            sleep 30
        fi

        if [[ $(oc get csv -n ${install_namespace} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
            echo "${package_name} is deployed"
            break
        else
            echo "Try ${i}/${RETRIES}: ${package_name} is not deployed yet. Checking again in 30 seconds"
            sleep 30
        fi
    done

    if [[ $(oc get csv -n "${install_namespace}" "${CSV}" -o jsonpath='{.status.phase}') != "Succeeded" ]]; then
        echo "Error: Failed to deploy ${package_name}"
        echo
        echo "Assert that the '${package_name}' packagemanifest belongs to '${CATALOGSOURCE_NAME}' catalog"
        echo
        oc get packagemanifest | grep ${package_name} || echo
        echo "CSV ${CSV} YAML"
        oc get csv "${CSV}" -n "${install_namespace}" -o yaml
        echo
        echo "CSV ${CSV} Describe"
        oc describe csv "${CSV}" -n "${install_namespace}"
        exit 1
    fi

    echo "Successfully installed ${package_name}"
}

function create_catalog_sources()
{
    # get cluster Major.Minor version
    kube_major=$(oc version -o json |jq -r '.serverVersion.major')
    kube_minor=$(oc version -o json |jq -r '.serverVersion.minor' | sed 's/+$//')

    echo "Create QE catalogsource: $CATALOGSOURCE_NAME"
    echo "Use $index_image in catalogsource/$CATALOGSOURCE_NAME"

    run_command "oc delete catsrc $CATALOGSOURCE_NAME -n openshift-marketplace --ignore-not-found=true"
    # since OCP 4.15, the official catalogsource use this way. OCP4.14=K8s1.27
    # details: https://issues.redhat.com/browse/OCPBUGS-31427
    if [[ ${kube_major} -gt 1 || ${kube_minor} -gt 27 ]]; then
        echo "the index image as the initContainer cache image)"
        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATALOGSOURCE_NAME
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
  name: $CATALOGSOURCE_NAME
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
        STATUS=`oc -n openshift-marketplace get catalogsource $CATALOGSOURCE_NAME -o=jsonpath="{.status.connectionState.lastObservedState}"`
        if [[ $STATUS = "READY" ]]; then
            echo "create the QE CatalogSource successfully"
            break
        fi
    done
    if [[ $STATUS != "READY" ]]; then
        echo "!!! fail to create QE CatalogSource"
        run_command "oc get pods -o wide -n openshift-marketplace"
        run_command "oc -n openshift-marketplace get catalogsource $CATALOGSOURCE_NAME -o yaml"
        run_command "oc -n openshift-marketplace get pods -l olm.catalogSource=$CATALOGSOURCE_NAME -o yaml"
        node_name=$(oc -n openshift-marketplace get pods -l olm.catalogSource=$CATALOGSOURCE_NAME -o=jsonpath='{.items[0].spec.nodeName}')
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

run_command "echo $PATH"
run_command "ls -l /cli"
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

if [[ ! -z ${index_image} ]]; then
    check_marketplace
    create_catalog_sources
    subscribe_operator "cluster-logging" "openshift-logging"
    subscribe_operator "loki-operator" "openshift-operators-redhat"
else
    echo "Install operator via operator-sdk"
    # install operator-sdk
    export HOME=/tmp/home
    mkdir -p "${HOME}"
    export PATH=$PATH:$HOME
    cd $HOME
    ARCH=$(case $(uname -m) in x86_64) echo -n amd64 ;; aarch64) echo -n arm64 ;; *) echo -n "$(uname -m)" ;; esac)
    export ARCH
    OS=$(uname | awk '{print tolower($0)}')
    export OS
    export OPERATOR_SDK_DL_URL=https://github.com/operator-framework/operator-sdk/releases/download/v1.41.1
    run_command "curl -L ${OPERATOR_SDK_DL_URL}/operator-sdk_${OS}_${ARCH} -o operator-sdk"
    run_command "chmod +x operator-sdk"
    run_command "which operator-sdk && operator-sdk version"

    run_command "oc delete catsrc/qe-app-registry -n openshift-marketplace --ignore-not-found"
    # Before installing operators, sleep 5m for ICSP to be applied
    sleep 300

    OLD_IFS=$IFS
    IFS=','
    for bundle in $logging_bundles; do
        case "$bundle" in
            *"loki-operator-bundle"*)
            operator_sdk_install_operator $bundle "openshift-operators-redhat"
            ;;
            *"cluster-logging-operator-bundle"*)
            operator_sdk_install_operator $bundle "openshift-logging"
            ;;
            *)
            echo "unkonw bundle $bundle"
            ;;
        esac
    done
    IFS=$OLD_IFS
fi


#support hypershift config guest cluster's icsp
oc get imagecontentsourcepolicy -oyaml > /tmp/mgmt_icsp.yaml && yq-go r /tmp/mgmt_icsp.yaml 'items[*].spec.repositoryDigestMirrors' -  | sed  '/---*/d' > ${SHARED_DIR}/mgmt_icsp.yaml

run_command "oc get cm -n openshift-config-managed"
echo ""
run_command "oc get secret -n openshift-operators-redhat"
echo ""
run_command "oc get sub -A"
