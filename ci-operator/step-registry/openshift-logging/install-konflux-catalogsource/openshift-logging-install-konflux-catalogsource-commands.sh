#!/bin/bash

set -e
set -u
set -o pipefail

index_image="${MULTISTAGE_PARAM_OVERRIDE_LOGGING_INDEX_IMAGE/registry-proxy.engineering.redhat.com/brew.registry.redhat.io}"

if [[ -z ${index_image} ]] ; then
  echo "index_image is not set."
  exit 1
else
  echo "index_image is set to: ${index_image}"
fi

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
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
        if [[ -z ${MULTISTAGE_PARAM_OVERRIDE_LOGGING_TEST_VERSION} ]] ; then
            echo "MULTISTAGE_PARAM_OVERRIDE_LOGGING_TEST_VERSION is not set, can't create correct ICSP"
            exit 1
        fi
        image_version="${MULTISTAGE_PARAM_OVERRIDE_LOGGING_TEST_VERSION//./-}"
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
function check_olm_capability(){
    # check if OLMv0 capability is added
    knownCaps=`oc get clusterversion version -o=jsonpath="{.status.capabilities.knownCapabilities}"`
    if [[ ${knownCaps} =~ "OperatorLifecycleManager\"," ]]; then
        echo "knownCapabilities contains OperatorLifecycleManagerv0"
        # check if OLMv0 capability enabled
        enabledCaps=`oc get clusterversion version -o=jsonpath="{.status.capabilities.enabledCapabilities}"`
          if [[ ! ${enabledCaps} =~ "OperatorLifecycleManager\"," ]]; then
              echo "OperatorLifecycleManagerv0 capability is not enabled, skip the following tests..."
              exit 0
          fi
    fi
}

set_proxy
run_command "oc whoami"
run_command "which oc && oc version -o yaml"
update_global_auth
sleep 5
create_icsp_connected
check_olm_capability
check_marketplace
create_catalog_sources

#support hypershift config guest cluster's icsp
oc get imagecontentsourcepolicy -oyaml > /tmp/mgmt_icsp.yaml && yq-go r /tmp/mgmt_icsp.yaml 'items[*].spec.repositoryDigestMirrors' -  | sed  '/---*/d' > ${SHARED_DIR}/mgmt_icsp.yaml
