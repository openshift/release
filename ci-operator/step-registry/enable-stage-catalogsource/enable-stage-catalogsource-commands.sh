#!/bin/bash

set -e
set -u
set -o pipefail

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

function apply_mcp_config() {

    # Define the paths to the JSON files
    MASTER_JSON="/var/run/vault/dt-secrets/99-master-it-ca.json"
    WORKER_JSON="/var/run/vault/dt-secrets/99-worker-it-ca.json"

    # Create the machineconfigs from the JSON files
    oc create -f "$MASTER_JSON"
    oc create -f "$WORKER_JSON"

    sleep 10

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

  # Define the new dockerconfig path
  new_dockerconfig="/tmp/new-dockerconfigjson"

  # Read the stage registry credentials from the JSON file
  stage_auth_user=$(cat "/var/run/vault/mirror-registry/registry_stage.json" | jq -r '.user')
  stage_auth_password=$(cat "/var/run/vault/mirror-registry/registry_stage.json" | jq -r '.password')
  stage_registry_auth=$(echo -n "${stage_auth_user}:${stage_auth_password}" | base64 -w 0)

  # Create a new dockerconfig with the stage registry credentials without the "email" field
  jq --argjson a "{\"https://registry.stage.redhat.io\": {\"auth\": \"${stage_registry_auth}\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" > "${new_dockerconfig}"

  # update global auth
  ret=0
  run_command "oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=${new_dockerconfig}" || ret=$?
  if [[ $ret -eq 0 ]]; then
      apply_mcp_config
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
    #Delete any existing ImageContentSourcePolicy
    oc delete imagecontentsourcepolicies brew-registry
    oc delete catalogsource qe-app-registry -n openshift-marketplace

    cat <<EOF | oc create -f -
    apiVersion: operator.openshift.io/v1alpha1
    kind: ImageContentSourcePolicy
    metadata:
      name: dt-registry
    spec:
      repositoryDigestMirrors:
      - mirrors:
        - registry.stage.redhat.io
        source: registry.redhat.io
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
    ocp_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f1,2)
    index_image="registry.stage.redhat.io/redhat/redhat-operator-index:v${ocp_version}"

    echo "create Distributed Tracing  catalogsource: dt-catalogsource"
    cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: dt-catalogsource
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
    set +e 
    COUNTER=0
    while [ $COUNTER -lt 600 ]
    do
        sleep 20
        COUNTER=`expr $COUNTER + 20`
        echo "waiting ${COUNTER}s"
        STATUS=`oc -n openshift-marketplace get catalogsource dt-catalogsource -o=jsonpath="{.status.connectionState.lastObservedState}"`
        if [[ $STATUS = "READY" ]]; then
            echo "create the QE CatalogSource successfully"
            break
        fi
    done
    if [[ $STATUS != "READY" ]]; then
        echo "!!! fail to create QE CatalogSource"
        # ImagePullBackOff nothing with the imagePullSecrets 
        # run_command "oc get operatorgroup -n openshift-marketplace"
        # run_command "oc get sa dt-catalogsource -n openshift-marketplace -o yaml"
        # run_command "oc -n openshift-marketplace get secret $(oc -n openshift-marketplace get sa dt-catalogsource -o=jsonpath='{.secrets[0].name}') -o yaml"
        
        run_command "oc get pods -o wide -n openshift-marketplace"
        run_command "oc -n openshift-marketplace get catalogsource dt-catalogsource -o yaml"
        run_command "oc -n openshift-marketplace get pods -l olm.catalogSource=dt-catalogsource -o yaml"
        node_name=$(oc -n openshift-marketplace get pods -l olm.catalogSource=dt-catalogsource -o=jsonpath='{.items[0].spec.nodeName}')
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

set_proxy
run_command "oc whoami"
run_command "oc version -o yaml"
update_global_auth
sleep 5
create_icsp_connected
check_marketplace
create_catalog_sources

#support hypershift config guest cluster's icsp
oc get imagecontentsourcepolicy -oyaml > /tmp/mgmt_iscp.yaml && yq-go r /tmp/mgmt_iscp.yaml 'items[*].spec.repositoryDigestMirrors' -  | sed  '/---*/d' > ${SHARED_DIR}/mgmt_iscp.yaml
