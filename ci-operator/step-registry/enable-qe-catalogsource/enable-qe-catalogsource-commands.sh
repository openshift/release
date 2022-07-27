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

  # only add quay.io/openshift-qe-optional-operators auth to the global auth
  new_dockerconfig="/tmp/new-dockerconfigjson"
  # qe_registry_auth=$(cat "/var/run/vault/mirror-registry/qe_optional.json" | jq -r '.auths."quay.io/openshift-qe-optional-operators".auth')
  optional_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.user')
  optional_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.password')
  qe_registry_auth=`echo -n "${optional_auth_user}:${optional_auth_password}" | base64 -w 0`

  reg_brew_user=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.user')
  reg_brew_password=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.password')
  brew_registry_auth=`echo -n "${reg_brew_user}:${reg_brew_password}" | base64 -w 0`
  jq --argjson a "{\"brew.registry.redhat.io\": {\"auth\": \"${brew_registry_auth}\", \"email\":\"jiazha@redhat.com\"},\"quay.io/openshift-qe-optional-operators\": {\"auth\": \"${qe_registry_auth}\", \"email\":\"jiazha@redhat.com\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" > ${new_dockerconfig}

 # run_command "cat ${new_dockerconfig} | jq"

  # update global auth
  run_command "oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=${new_dockerconfig}"; ret=$?
  if [[ $ret -eq 0 ]]; then
      echo "update the cluster global auth successfully."
  else
      echo "!!! fail to add QE optional registry auth"
      return 1
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
    echo "create QE catalogsource: qe-app-registry"
    cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: qe-app-registry
  namespace: openshift-marketplace
spec:
  displayName: Production Operators
  image: quay.io/openshift-qe-optional-operators/ocp4-index:latest
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
        echo "!!! fail to create QE CatalogSource"\
        run_command "oc -n openshift-marketplace get pods"
        run_command "oc -n openshift-marketplace get catalogsource qe-app-registry -o yaml"
        run_command "oc -n openshift-marketplace get pods -l olm.catalogSource=qe-app-registry -o yaml"
        return 1
    fi
    set -e 
}

set_proxy
run_command "oc whoami"
run_command "oc version -o yaml"
update_global_auth
sleep 5
create_icsp_connected
create_catalog_sources
