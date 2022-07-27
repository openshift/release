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
        # add the custom registry auth to the .dockerconfigjson of the cluster

        # # quay.io
        # optional_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.user')
        # optional_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.password')
        # quay_auth=`echo -n "${optional_auth_user}:${optional_auth_password}" | base64 -w 0`
        # # brew.registry.redhat.io
        # reg_brew_user=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.user')
        # reg_brew_password=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.password')
        # brew_registry_auth=`echo -n "${reg_brew_user}:${reg_brew_password}" | base64 -w 0`
        # # registry.redhat.io
        # reg_user=$(cat "/var/run/vault/mirror-registry/registry.json" | jq -r '.user')
        # reg_password=$(cat "/var/run/vault/mirror-registry/registry.json" | jq -r '.password')
        # registry_auth=`echo -n "${reg_user}:${reg_password}" | base64 -w 0`
        # vmc.mirror-registry.qe.devcluster.openshift.com:6002
        # vmc.mirror-registry.qe.devcluster.openshift.com:6001
        registry_cred=`head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0`

        jq --argjson a "{\"${MIRROR_PROXY_REGISTRY_QUAY}\": {\"auth\": \"$registry_cred\"}, \"${MIRROR_PROXY_REGISTRY}\": {\"auth\": \"$registry_cred\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" > /tmp/new-dockerconfigjson
        # echo "$ cat /tmp/new-dockerconfigjson"
        # cat /tmp/new-dockerconfigjson
        # set the registry auth for the cluster
        run_command "oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/new-dockerconfigjson"; ret=$?
        if [[ $ret -eq 0 ]]; then
            echo "set the mirror registry auth successfully."
        else
            echo "!!! fail to set the mirror registry auth"
            return 1
        fi
    else
        echo "!!! fail to extract the auth of the cluster"
        return 1
    fi
}

function disable_default_catalogsource () {
    run_command "oc patch operatorhub cluster -p '{\"spec\": {\"disableAllDefaultSources\": true}}' --type=merge"; ret=$?
    if [[ $ret -eq 0 ]]; then
        echo "disable default Catalog Source successfully."
    else
        echo "!!! fail to disable default Catalog Source"
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

# Slove: x509: certificate signed by unknown authority
# Config CA for each cluster node so that it can pull images successfully.
# It not only be used by Sample operator, but ICSP and all pods that pulling images from the external registry.
# $ oc debug node/qe-daily-0721-p79bt-worker-3-knbkr
# sh-4.4# chroot /host
# sh-4.4# ls -l /etc/pki/ca-trust/source/anchors/
# total 0
# -rw-------. 1 root root 0 Jul 20 23:30 openshift-config-user-ca-bundle.crt
# sh-4.4# ls -l /etc/docker/certs.d
# total 0
# drwxr-xr-x. 2 1001 root 20 Jul 20 23:30 image-registry.openshift-image-registry.svc.cluster.local:5000
# drwxr-xr-x. 2 1001 root 20 Jul 20 23:30 image-registry.openshift-image-registry.svc:5000
# drwxr-xr-x. 2 1001 root 20 Jul 21 03:30 vmc.mirror-registry.qe.devcluster.openshift.com:5000
# drwxr-xr-x. 2 1001 root 20 Jul 21 03:30 vmc.mirror-registry.qe.devcluster.openshift.com:6001
# drwxr-xr-x. 2 1001 root 20 Jul 21 03:30 vmc.mirror-registry.qe.devcluster.openshift.com:6002
function set_CA_for_nodes () {
    ca_name=$(oc get image.config.openshift.io/cluster -o=jsonpath="{.spec.additionalTrustedCA.name}")
    if [ $ca_name ] && [ $ca_name = "registry-config" ] ; then
        echo "CA is ready, skip config..."
        return 0
    fi

    # get the QE additional CA
    QE_ADDITIONAL_CA_FILE="/var/run/vault/mirror-registry/additional_ca"
    REGISTRY_HOST=`echo ${MIRROR_PROXY_REGISTRY} | cut -d \: -f 1`
    # Configuring additional trust stores for image registry access, details: https://docs.openshift.com/container-platform/4.11/registry/configuring-registry-operator.html#images-configuration-cas_configuring-registry-operator
    run_command "oc create configmap registry-config --from-file=\"${REGISTRY_HOST}..5000\"=${QE_ADDITIONAL_CA_FILE} --from-file=\"${REGISTRY_HOST}..6001\"=${QE_ADDITIONAL_CA_FILE} --from-file=\"${REGISTRY_HOST}..6002\"=${QE_ADDITIONAL_CA_FILE}  -n openshift-config"; ret=$?
    if [[ $ret -eq 0 ]]; then
        echo "set the proxy registry ConfigMap successfully."
    else
        echo "!!! fail to set the proxy registry ConfigMap"
        run_command "oc get configmap registry-config -n openshift-config -o yaml"
        return 1
    fi
    run_command "oc patch image.config.openshift.io/cluster --patch '{\"spec\":{\"additionalTrustedCA\":{\"name\":\"registry-config\"}}}' --type=merge"; ret=$?
    if [[ $ret -eq 0 ]]; then
        echo "set additionalTrustedCA successfully."
    else
        echo "!!! Fail to set additionalTrustedCA"
        run_command "oc get image.config.openshift.io/cluster -o yaml"
        return 1
    fi
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
    set +e 
    COUNTER=0
    while [ $COUNTER -lt 30 ]
    do
        sleep 20
        COUNTER=`expr $COUNTER + 20`
        echo "waiting ${COUNTER}s"
        STATUS=`oc -n openshift-marketplace get catalogsource qe-app-registry -o=jsonpath="{.status.connectionState.lastObservedState}"`
        if [ $STATUS = "READY" ]; then
            echo "create the QE CatalogSource successfully"
            COUNTER=100
            break
        fi
    done
    if [ $COUNTER -ne 100 ]; then
        echo "!!! fail to create QE CatalogSource"
        run_command "oc -n openshift-marketplace get pods"
        run_command "oc -n openshift-marketplace get catalogsource qe-app-registry -o yaml"
        run_command "oc -n openshift-marketplace get pods -l olm.catalogSource=qe-app-registry -o yaml"
        return 1
    fi
    set -e 
}

function check_default_catalog () {
    COUNTER=0
    while [ $COUNTER -lt 600 ]
    do
        sleep 1
        COUNTER=`expr $COUNTER + 1`
        echo "waiting ${COUNTER}s"
        STATUS=`oc -n openshift-marketplace get catalogsource redhat-operators -o=jsonpath="{.status.connectionState.lastObservedState}"`
        if [ $STATUS = "READY" ]; then
            echo "The default CatalogSource works well"
            COUNTER=100
            break
        fi
    done
    if [ $COUNTER -ne 100 ]; then
        echo "!!! The default CatalogSource doen's work."
        run_command "oc get catalogsource -n openshift-marketplace"
        run_command "oc get pods -n openshift-marketplace"
        return 1
    fi
}

set_proxy
run_command "oc whoami"
run_command "oc version -o yaml"

# private mirror registry host
# <public_dns>:<port>
MIRROR_REGISTRY_HOST=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
echo "MIRROR_REGISTRY_HOST: ${MIRROR_REGISTRY_HOST}"
# the proxy registry port 6001 for quay.io
MIRROR_PROXY_REGISTRY_QUAY=`echo "${MIRROR_REGISTRY_HOST}" | sed 's/5000/6001/g' `
echo "MIRROR_PROXY_REGISTRY_QUAY: ${MIRROR_PROXY_REGISTRY_QUAY}"
# the proxy registry port 6002 for redhat.io
MIRROR_PROXY_REGISTRY=`echo "${MIRROR_REGISTRY_HOST}" | sed 's/5000/6002/g' `
echo "MIRROR_PROXY_REGISTRY: ${MIRROR_PROXY_REGISTRY}"
set_cluster_auth
set_CA_for_nodes
create_settled_icsp
create_catalog_sources
# For now(2022-07-19), the Proxy registry can only proxy the `brew.registry.redhat.io` image, 
# but the default CatalogSource use `registry.redhat.io` image, such as registry.redhat.io/redhat/redhat-operator-index:v4.11
# And, there is no brew.registry.redhat.io/redhat/redhat-operator-index:v4.11 , so disable the default CatalogSources.
# TODO: the Proxy registry support the `registry.redhat.io` images
# check_default_catalog
disable_default_catalogsource
