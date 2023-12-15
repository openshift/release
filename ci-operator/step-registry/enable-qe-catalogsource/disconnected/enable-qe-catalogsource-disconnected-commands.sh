#!/bin/bash

set -e
set -u
set -o pipefail

# use it as a bool
marketplace=0
mirror=0

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

function unset_proxy () {
    if test -s "${SHARED_DIR}/unset-proxy.sh" ; then
        echo "unset the proxy"
        echo "source ${SHARED_DIR}/unset-proxy.sh"
        source "${SHARED_DIR}/unset-proxy.sh"
    else
        echo "no proxy setting found."
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
            check_mcp_status
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
# function create_icsp_by_olm () {
#     mirror_auths="${SHARED_DIR}/mirror_auths"
#     # Don't mirror OLM operators images, but create the ICSP for them.
#     echo "===>>> create ICSP for OLM operators"
#     run_command "oc adm catalog mirror -a ${mirror_auths} quay.io/openshift-qe-optional-operators/ocp4-index:latest ${MIRROR_REGISTRY_HOST} --manifests-only --to-manifests=/tmp/olm_mirror"; ret=$?
#     if [[ $ret -eq 0 ]]; then
#         run_command "cat /tmp/olm_mirror/imageContentSourcePolicy.yaml"
#         run_command "oc create -f /tmp/olm_mirror/imageContentSourcePolicy.yaml"; ret=$?
#         if [[ $ret -eq 0 ]]; then
#             echo "create the ICSP resource successfully"
#         else
#             echo "!!! fail to create the ICSP resource"
#             return 1
#         fi
#     else
#         echo "!!! fail to generate the ICSP for OLM operators"
#         # cat ${mirror_auths}
#         return 1
#     fi
#     rm -rf /tmp/olm_mirror 
# }

# this func only used when the cluster not set the Proxy registy, such as C2S, SC2S clusters
function mirror_optional_images () {
    registry_cred=`head -n 1 "/var/run/vault/mirror-registry/registry_creds" | base64 -w 0`

    optional_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.user')
    optional_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.password')
    qe_registry_auth=`echo -n "${optional_auth_user}:${optional_auth_password}" | base64 -w 0`

    openshifttest_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.user')
    openshifttest_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.password')
    openshifttest_registry_auth=`echo -n "${openshifttest_auth_user}:${openshifttest_auth_password}" | base64 -w 0`

    brew_auth_user=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.user')
    brew_auth_password=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.password')
    brew_registry_auth=`echo -n "${brew_auth_user}:${brew_auth_password}" | base64 -w 0`

    stage_auth_user=$(cat "/var/run/vault/mirror-registry/registry_stage.json" | jq -r '.user')
    stage_auth_password=$(cat "/var/run/vault/mirror-registry/registry_stage.json" | jq -r '.password')
    stage_registry_auth=`echo -n "${stage_auth_user}:${stage_auth_password}" | base64 -w 0`

    redhat_auth_user=$(cat "/var/run/vault/mirror-registry/registry_redhat.json" | jq -r '.user')
    redhat_auth_password=$(cat "/var/run/vault/mirror-registry/registry_redhat.json" | jq -r '.password')
    redhat_registry_auth=`echo -n "${redhat_auth_user}:${redhat_auth_password}" | base64 -w 0`

    # run_command "cat ${CLUSTER_PROFILE_DIR}/pull-secret"
    # Running Command: cat /tmp/.dockerconfigjson
    # {"auths":{"ec2-3-92-162-185.compute-1.amazonaws.com:5000":{"auth":"XXXXXXXXXXXXXXXX"}}}
    run_command "oc extract secret/pull-secret -n openshift-config --confirm --to /tmp"; ret=$?
    if [[ $ret -eq 0 ]]; then 
        jq --argjson a "{\"registry.stage.redhat.io\": {\"auth\": \"$stage_registry_auth\"}, \"brew.registry.redhat.io\": {\"auth\": \"$brew_registry_auth\"}, \"registry.redhat.io\": {\"auth\": \"$redhat_registry_auth\"}, \"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}, \"quay.io/openshift-qe-optional-operators\": {\"auth\": \"${qe_registry_auth}\", \"email\":\"jiazha@redhat.com\"},\"quay.io/openshifttest\": {\"auth\": \"${openshifttest_registry_auth}\"}}" '.auths |= . + $a' "/tmp/.dockerconfigjson" > /tmp/new-dockerconfigjson
    else
        echo "!!! fail to extract the auth of the cluster"
        return 1
    fi
    
    unset_proxy
    ret=0
    # Running Command: oc adm catalog mirror -a "/tmp/new-dockerconfigjson" ec2-3-90-59-26.compute-1.amazonaws.com:5000/openshift-qe-optional-operators/aosqe-index:v4.12 ec2-3-90-59-26.compute-1.amazonaws.com:5000 --continue-on-error --to-manifests=/tmp/olm_mirror
    # error: unable to read image ec2-3-90-59-26.compute-1.amazonaws.com:5000/openshift-qe-optional-operators/aosqe-index:v4.12: Get "https://ec2-3-90-59-26.compute-1.amazonaws.com:5000/v2/": x509: certificate signed by unknown authority
    run_command "oc adm catalog mirror  --insecure=true  --skip-verification=true -a \"/tmp/new-dockerconfigjson\" ${origin_index_image} ${MIRROR_REGISTRY_HOST} --to-manifests=/tmp/olm_mirror" || ret=$?
    if [[ $ret -eq 0 ]]; then
        echo "mirror optional operators' images successfully"
    else
        run_command "cat /tmp/olm_mirror/imageContentSourcePolicy.yaml"
        run_command "cat /tmp/olm_mirror/mapping.txt"
        return 1
    fi
    set_proxy
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
    QE_ADDITIONAL_CA_FILE="/var/run/vault/mirror-registry/client_ca.crt"
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
  image: ${mirror_index_image}
  publisher: OpenShift QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
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
        run_command "oc -n debug-qe debug node/${node_name} -- chroot /host podman pull --authfile /var/lib/kubelet/config.json ${mirror_index_image}"

        run_command "oc get mcp,node"
        run_command "oc get mcp worker -o yaml"
        run_command "oc get mc $(oc get mcp/worker --no-headers | awk '{print $2}') -o=jsonpath={.spec.config.storage.files}|jq '.[] | select(.path==\"/var/lib/kubelet/config.json\")'"

        return 1
    fi
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
    marketplace=1
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

# private mirror registry host
# <public_dns>:<port>
MIRROR_REGISTRY_HOST=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
# the proxy registry port 6001 for quay.io
MIRROR_PROXY_REGISTRY_QUAY=`echo "${MIRROR_REGISTRY_HOST}" | sed 's/5000/6001/g' `
# the proxy registry port 6002 for redhat.io
MIRROR_PROXY_REGISTRY=`echo "${MIRROR_REGISTRY_HOST}" | sed 's/5000/6002/g' `

# we don't set the proxy registy for the C2S and SC2S clusters, so use the default mirror registry port: 5000
platform=`oc get infrastructure cluster -o=jsonpath="{.status.platform}"`
echo "The platform is ${platform}"
if [[ $platform == "AWS" ]]; then
    region=`oc get infrastructure cluster -o=jsonpath="{.status.platformStatus.aws.region}"`
    echo "The region is ${region}"
    if [[ $region =~ ^us-iso(b)?-.* ]]; then
        echo "This cluster is a C2S or SC2S cluster(region us-iso-* represent C2S, us-isob-* represent SC2S), so don't use the proxy registry."
        # change it back to the default port 5000
        MIRROR_PROXY_REGISTRY_QUAY=${MIRROR_REGISTRY_HOST}
        MIRROR_PROXY_REGISTRY=${MIRROR_REGISTRY_HOST}
        mirror=1
    fi
fi

echo "MIRROR_REGISTRY_HOST: ${MIRROR_REGISTRY_HOST}"
echo "MIRROR_PROXY_REGISTRY_QUAY: ${MIRROR_PROXY_REGISTRY_QUAY}"
echo "MIRROR_PROXY_REGISTRY: ${MIRROR_PROXY_REGISTRY}"

set_CA_for_nodes
# get cluster Major.Minor version
ocp_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f1,2)
origin_index_image="quay.io/openshift-qe-optional-operators/aosqe-index:v${ocp_version}"
mirror_index_image="${MIRROR_PROXY_REGISTRY_QUAY}/openshift-qe-optional-operators/aosqe-index:v${ocp_version}"

if [ $mirror -eq 1 ]; then
    mirror_optional_images
else
    # no need to set auth for the MIRROR_REGISTRY_HOST
    set_cluster_auth
fi 

create_settled_icsp
check_olm_capability
check_marketplace
# No need to disable the default OperatorHub when marketplace disabled as default.
if [ $marketplace -eq 0 ]; then
    disable_default_catalogsource
fi
create_catalog_sources
# For now(2022-07-19), the Proxy registry can only proxy the `brew.registry.redhat.io` image, 
# but the default CatalogSource use `registry.redhat.io` image, such as registry.redhat.io/redhat/redhat-operator-index:v4.11
# And, there is no brew.registry.redhat.io/redhat/redhat-operator-index:v4.11 , so disable the default CatalogSources.
# TODO: the Proxy registry support the `registry.redhat.io` images
# check_default_catalog
