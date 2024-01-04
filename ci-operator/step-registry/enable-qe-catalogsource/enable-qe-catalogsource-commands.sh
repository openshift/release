#!/bin/bash

set -e
set -u
set -o pipefail

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
 # run_command "cat /tmp/.dockerconfigjson | jq"

  # replace all global auth with the QE's
  # new_dockerconfig="/var/run/vault/image-registry/qe_dockerconfigjson"

  # add quay.io/openshift-qe-optional-operators and quay.io/openshifttest auth to the global auth
  new_dockerconfig="/tmp/new-dockerconfigjson"
  # qe_registry_auth=$(cat "/var/run/vault/mirror-registry/qe_optional.json" | jq -r '.auths."quay.io/openshift-qe-optional-operators".auth')
  optional_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.user')
  optional_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.password')
  qe_registry_auth=`echo -n "${optional_auth_user}:${optional_auth_password}" | base64 -w 0`

  openshifttest_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.user')
  openshifttest_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.password')
  openshifttest_registry_auth=`echo -n "${openshifttest_auth_user}:${openshifttest_auth_password}" | base64 -w 0`

  reg_brew_user=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.user')
  reg_brew_password=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.password')
  brew_registry_auth=`echo -n "${reg_brew_user}:${reg_brew_password}" | base64 -w 0`
  jq --argjson a "{\"brew.registry.redhat.io\": {\"auth\": \"${brew_registry_auth}\", \"email\":\"jiazha@redhat.com\"},\"quay.io/openshift-qe-optional-operators\": {\"auth\": \"${qe_registry_auth}\", \"email\":\"jiazha@redhat.com\"},\"quay.io/openshifttest\": {\"auth\": \"${openshifttest_registry_auth}\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" > ${new_dockerconfig}

 # run_command "cat ${new_dockerconfig} | jq"

  # update global auth
  ret=0
  run_command "oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=${new_dockerconfig}" || ret=$?
  if [[ $ret -eq 0 ]]; then
      check_mcp_status
      echo "update the cluster global auth successfully."
  else
      echo "!!! fail to add QE optional registry auth, retry and enable log..."
      sleep 1
      ret=0
      run_command "oc --loglevel=10 set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=${new_dockerconfig}" || ret=$?
      if [[ $ret -eq 0 ]]; then
        echo "update the cluster global auth successfully after retry."
      else
        echo "!!! still fail to add QE optional registry auth after retry"
        return 1
      fi
  fi
}

# create ICSP for connected env.
function create_icsp_connected () {
    cat <<EOF | oc create -f -
    apiVersion: operator.openshift.io/v1alpha1
    kind: ImageContentSourcePolicy
    metadata:
      name: brew-registry
    spec:
      repositoryDigestMirrors:
      - mirrors:
        - brew.registry.redhat.io
        source: registry.redhat.io
      - mirrors:
        - brew.registry.redhat.io
        source: registry.stage.redhat.io
      - mirrors:
        - brew.registry.redhat.io
        source: registry-proxy.engineering.redhat.com
EOF
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
    kube_minor=$(oc version -o json |jq -r '.serverVersion.minor')
    index_image="quay.io/openshift-qe-optional-operators/aosqe-index:v${kube_major}.${kube_minor}"

    echo "Create QE catalogsource: qe-app-registry"
    echo "Use $index_image in catalogsource/qe-app-registry"
    cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: qe-app-registry
  namespace: openshift-marketplace
  annotations:
    olm.catalogImageTemplate: "quay.io/openshift-qe-optional-operators/aosqe-index:v{kube_major_version}.{kube_minor_version}"
spec:
  displayName: Production Operators
  image: ${index_image}
  publisher: OpenShift QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
    set +e 
    COUNTER=0
    while [ $COUNTER -lt 600 ]
    do
        sleep 20
        COUNTER=`expr $COUNTER + 20`
        echo "waiting ${COUNTER}s"
        STATUS=`oc -n openshift-marketplace get catalogsource qe-app-registry -o=jsonpath="{.status.connectionState.lastObservedState}"`
        if [[ $STATUS = "READY" ]]; then
            echo "create the QE CatalogSource successfully"
            break
        fi
    done
    if [[ $STATUS != "READY" ]]; then
        echo "!!! fail to create QE CatalogSource"
        # ImagePullBackOff nothing with the imagePullSecrets 
        # run_command "oc get operatorgroup -n openshift-marketplace"
        # run_command "oc get sa qe-app-registry -n openshift-marketplace -o yaml"
        # run_command "oc -n openshift-marketplace get secret $(oc -n openshift-marketplace get sa qe-app-registry -o=jsonpath='{.secrets[0].name}') -o yaml"
        
        run_command "oc get pods -o wide -n openshift-marketplace"
        run_command "oc -n openshift-marketplace get catalogsource qe-app-registry -o yaml"
        run_command "oc -n openshift-marketplace get pods -l olm.catalogSource=qe-app-registry -o yaml"
        node_name=$(oc -n openshift-marketplace get pods -l olm.catalogSource=qe-app-registry -o=jsonpath='{.items[0].spec.nodeName}')
        run_command "oc create ns debug-qe -o yaml | oc label -f - security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite"
        run_command "oc -n debug-qe debug node/${node_name} -- chroot /host podman pull --authfile /var/lib/kubelet/config.json ${index_image}"
        
        run_command "oc get mcp,node"
        run_command "oc get mcp worker -o yaml"
        run_command "oc get mc $(oc get mcp/worker --no-headers | awk '{print $2}') -o=jsonpath={.spec.config.storage.files}|jq '.[] | select(.path==\"/var/lib/kubelet/config.json\")'"

        return 1
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
function check_olm_capability(){
    # check if OLM capability is added 
    knownCaps=`oc get clusterversion version -o=jsonpath="{.status.capabilities.knownCapabilities}"`
    if [[ ${knownCaps} =~ "OperatorLifecycleManager" ]]; then
        echo "knownCapabilities contains OperatorLifecycleManager"
        # check if OLM capability enabled
        enabledCaps=`oc get clusterversion version -o=jsonpath="{.status.capabilities.enabledCapabilities}"`
          if [[ ! ${enabledCaps} =~ "OperatorLifecycleManager" ]]; then
              echo "OperatorLifecycleManager capability is not enabled, skip the following tests..."
              exit 0
          fi
    fi
}

set_proxy
run_command "oc whoami"
run_command "oc version -o yaml"
check_olm_capability
update_global_auth
sleep 5
create_icsp_connected
check_marketplace
create_catalog_sources

#support hypershift config guest cluster's icsp
oc get imagecontentsourcepolicy -oyaml > /tmp/mgmt_iscp.yaml && yq-go r /tmp/mgmt_iscp.yaml 'items[*].spec.repositoryDigestMirrors' -  | sed  '/---*/d' > ${SHARED_DIR}/mgmt_iscp.yaml
