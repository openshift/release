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

# set the registry auths for the cluster
function set_cluster_auth () {
    # get the registry configures of the cluster
    run_command "oc extract secret/pull-secret -n openshift-config --confirm --to /tmp"; ret=$?
    if [[ $ret -eq 0 ]]; then 
        # reminder: there is no brew pull secret here
        # echo "$ cat /tmp/.dockerconfigjson"
        # cat /tmp/.dockerconfigjson
        # add the custom registry auth to the .dockerconfigjson of the cluster
        registry_cred=`head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0`
        jq --argjson a "{\"${MIRROR_PROXY_REGISTRY_QUAY}\": {\"auth\": \"$registry_cred\"}, \"${MIRROR_PROXY_REGISTRY}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" > /tmp/new-dockerconfigjson
        # echo "$ cat /tmp/new-dockerconfigjson"
        # cat /tmp/new-dockerconfigjson
        # set the registry auth for the cluster
        run_command "oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/new-dockerconfigjson"; ret=$?
        if [[ $ret -eq 0 ]]; then
            echo "set the mirror registry auth succeessfully."
        else
            echo "!!! fail to set the mirror registry auth"
            return 1
        fi
    else
        echo "!!! fail to extract the auth of the cluster"
        return 1
    fi
}

# Create the ICSP for optional operators dynamiclly, but we don't use it here
function create_icsp_by_olm () {
    mirror_auths="${SHARED_DIR}/mirror_auths"
    # Don't mirror OLM operators images, but create the ICSP for them.
    echo "===>>> create ICSP for OLM operators"
    run_command "oc adm catalog mirror -a ${mirror_auths} quay.io/openshift-qe-optional-operators/ocp4-index:latest ${MIRROR_REGISTRY_HOST} --manifests-only --to-manifests=/tmp/olm_mirror"; ret=$?
    if [[ $ret -eq 0 ]]; then
        run_command "cat /tmp/olm_mirror/imageContentSourcePolicy.yaml"
        run_command "oc create -f /tmp/olm_mirror/imageContentSourcePolicy.yaml"; ret=$?
        if [[ $ret -eq 0 ]]; then
            echo "create the ICSP resource successfully"
        else
            echo "!!! fail to create the ICSP resource"
            return 1
        fi
    else
        echo "!!! fail to generate the ICSP for OLM operators"
        # cat ${mirror_auths}
        return 1
    fi
    rm -rf /tmp/olm_mirror 
}

# Create the fixed ICSP for optional operators
function create_settled_icsp () {
    cat <<EOF | oc create -f -
    apiVersion: operator.openshift.io/v1alpha1
    kind: ImageContentSourcePolicy
    metadata:
      name: image-policy-aosqe
    spec:
      repositoryDigestMirrors:
      - mirrors:
        - ${MIRROR_PROXY_REGISTRY_QUAY}/openshifttest
        source: quay.io/openshifttest
      - mirrors:
        - ${MIRROR_PROXY_REGISTRY_QUAY}/openshift-qe-optional-operators
        source: quay.io/openshift-qe-optional-operators
      - mirrors:
        - ${MIRROR_PROXY_REGISTRY_QUAY}/olmqe
        source: quay.io/olmqe
      - mirrors:
        - ${MIRROR_PROXY_REGISTRY}
        source: registry.redhat.io
      - mirrors:
        - ${MIRROR_PROXY_REGISTRY}
        source: brew.registry.redhat.io
      - mirrors:
        - ${MIRROR_PROXY_REGISTRY}
        source: registry.stage.redhat.io
      - mirrors:
        - ${MIRROR_PROXY_REGISTRY}
        source: registry-proxy.engineering.redhat.com
EOF
    if [ $? == 0 ]; then
        echo "create the ICSP successfully" 
    else
        echo "!!! fail to create the ICSP"
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
  image: ${MIRROR_PROXY_REGISTRY_QUAY}/openshift-qe-optional-operators/ocp4-index:latest
  publisher: OpenShift QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
    if [ $? == 0 ]; then
        echo "create the QE CatalogSource successfully" 
    else
        echo "!!! fail to create QE CatalogSource"
        return 1
    fi
}


set_proxy
run_command "oc whoami"
run_command "oc version"

# private mirror registry host
# <public_dns>:<port>
MIRROR_REGISTRY_HOST=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist."
    # if the mirror registry doesn't exist, it more like a connected env
    create_icsp_connected
    create_catalog_sources
else
    echo "MIRROR_REGISTRY_HOST: ${MIRROR_REGISTRY_HOST}"
    # the proxy registry port 6001 for quay.io
    MIRROR_PROXY_REGISTRY_QUAY=`echo "${MIRROR_REGISTRY_HOST}" | sed 's/5000/6001/g' `
    echo "MIRROR_PROXY_REGISTRY_QUAY: ${MIRROR_PROXY_REGISTRY_QUAY}"
    # the proxy registry port 6002 for redhat.io
    MIRROR_PROXY_REGISTRY=`echo "${MIRROR_REGISTRY_HOST}" | sed 's/5000/6002/g' `
    echo "MIRROR_PROXY_REGISTRY: ${MIRROR_PROXY_REGISTRY}"
    set_cluster_auth
    create_settled_icsp
    create_catalog_sources
fi




