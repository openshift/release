#!/bin/bash
# Setup mirror registry credential and ICSP when proxy registry is used.
# Enable openshift qe catalogsource when OLM and marketplace is avaiable
# mirror operator images into local mirror registry when cluster type is c2s or sc2s
# The script exit 1 if fail to create mirror registry credential or ICSP.
# The script exit 0 if fail to mirror images. this allows the other test can be executed continuously
# The script exit 0 if fail to create catalogsource. this allows  the other test can be executed continuously
set -u
# use it as a bool
marketplace=0
mirror=0

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
	export no_proxy=brew.registry.redhat.io,registry.stage.redhat.io,registry.redhat.io,registry.ci.openshift.org,quay.io,s3.us-east-1.amazonaws.com
	export NO_PROXY=brew.registry.redhat.io,registry.stage.redhat.io,registry.redhat.io,registry.ci.openshift.org,quay.io,s3.us-east-1.amazonaws.com
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

function patch_clustercatalog_if_exists() {
    local catalog_name="$1"
    local retry_count=0
    local max_retries=3

    while [[ $retry_count -lt $max_retries ]]; do
        set +e
        error_output=$(oc get clustercatalog "$catalog_name" 2>&1)
        get_exit_code=$?
        set -e

        if [[ $get_exit_code -eq 0 ]]; then
            # Resource exists, patch it
            run_command "oc patch clustercatalog $catalog_name -p '{\"spec\": {\"availabilityMode\": \"Unavailable\"}}' --type=merge"
            return 0
        elif echo "$error_output" | grep -qiE "(NotFound|not found|could not find)"; then
            # Resource doesn't exist, this is expected in some versions
            echo "$catalog_name clustercatalog does not exist, skipping..."
            return 0
        else
            # Some other error occurred
            retry_count=$((retry_count + 1))
            if [[ $retry_count -lt $max_retries ]]; then
                echo "Warning: failed to check $catalog_name clustercatalog (attempt $retry_count/$max_retries): $error_output"
                echo "Retrying in 5 seconds..."
                sleep 5
            else
                echo "Error: failed to check $catalog_name clustercatalog after $max_retries attempts: $error_output"
                return 1
            fi
        fi
    done
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
	    return 0
        else
            echo "!!! fail to set the mirror registry auth"
            return 1
        fi
    else
        echo "Can not extract Auth of the cluster"
        echo "!!! fail to set the mirror registry auth"
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
    ocp_version=$(oc get -o jsonpath='{.status.desired.version}' clusterversion version)
    major_version=$(echo ${ocp_version} | cut -d '.' -f1)
    minor_version=$(echo ${ocp_version} | cut -d '.' -f2)
    if [[ "X${major_version}" == "X4" && -n "${minor_version}" && "${minor_version}" -gt 17 ]]; then
        echo "disable olmv1 default clustercatalog"
        run_command "oc patch clustercatalog openshift-certified-operators -p '{\"spec\": {\"availabilityMode\": \"Unavailable\"}}' --type=merge"
        run_command "oc patch clustercatalog openshift-redhat-operators -p '{\"spec\": {\"availabilityMode\": \"Unavailable\"}}' --type=merge"
        # openshift-redhat-marketplace was removed in 4.22, so check if it exists first
        patch_clustercatalog_if_exists "openshift-redhat-marketplace" || return 1
        run_command "oc patch clustercatalog openshift-community-operators -p '{\"spec\": {\"availabilityMode\": \"Unavailable\"}}' --type=merge"
        run_command "oc get clustercatalog"
    fi
}

# this func only used when the cluster not set the Proxy registy, such as C2S, SC2S clusters
function mirror_optional_images () {
    echo "Configuring credentials that allow images to be mirrored"
    mirror_registry_cred_file="/var/run/vault/mirror-registry/registry_creds"
    mirror_registry_user=`cat $mirror_registry_cred_file|cut -d: -f1`
    mirror_registry_password=`cat $mirror_registry_cred_file|cut -d: -f2`

    optional_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.user')
    optional_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.password')

    brew_auth_user=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.user')
    brew_auth_password=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.password')

    #stage_auth_user=$(cat "/var/run/vault/mirror-registry/registry_stage.json" | jq -r '.user')
    #stage_auth_password=$(cat "/var/run/vault/mirror-registry/registry_stage.json" | jq -r '.password')

    redhat_auth_user=$(cat "/var/run/vault/mirror-registry/registry_redhat.json" | jq -r '.user')
    redhat_auth_password=$(cat "/var/run/vault/mirror-registry/registry_redhat.json" | jq -r '.password')

    work_dir="/tmp"
    #https://docs.openshift.com/container-platform/4.16/installing/disconnected_install/installing-mirroring-disconnected.html
    #The default XDG_RUNTIME_DIR /var/run can not be edit in a pod. Replace /var/run with /tmp in this script
    export XDG_RUNTIME_DIR=$work_dir
    export REGISTRY_AUTH_FILE="$XDG_RUNTIME_DIR/containers/auth.json"
    # skopeo login create/update the REGISTRY_AUTH_FILE
    echo "REGISTRY_AUTH_FILE is $REGISTRY_AUTH_FILE"
    skopeo login ${MIRROR_REGISTRY_HOST} -u ${mirror_registry_user} -p ${mirror_registry_password} --tls-verify=false
    skopeo login brew.registry.redhat.io -u ${brew_auth_user} -p ${brew_auth_password} --tls-verify=false
    skopeo login registry.redhat.io -u ${redhat_auth_user} -p ${redhat_auth_password}
    skopeo login quay.io/openshift-qe-optional-operators -u ${optional_auth_user} -p ${optional_auth_password}

    echo "skopeo copy docker://${origin_index_image} oci://${work_dir}/oci-local-catalog --remove-signatures"

    RETRY_COUNT=0
    MAX_RETRIES=3

    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        set +e
        skopeo copy --all docker://${origin_index_image} "oci://${work_dir}/oci-local-catalog" --remove-signatures --src-tls-verify=false
        COPY_STATUS=$?
        set -e
        if [ $COPY_STATUS -eq 0 ]; then
            echo "Copy succeeded"
            break
        else
            RETRY_COUNT=$((RETRY_COUNT + 1))
            echo "Retry $RETRY_COUNT/$MAX_RETRIES..."
            sleep 30
        fi
    done

    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo "Failed after $MAX_RETRIES retries"
        exit 1
    fi

    echo "create ImageSetConfiguration"
    cat <<EOF >${work_dir}/imageset-config.yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v1alpha2
mirror:
  operators:
  - catalog: "oci://${work_dir}/oci-local-catalog"
    targetCatalog: "openshift-qe-optional-operators/aosqe-index"
    targetTag: "v${kube_major}.${kube_minor}"
EOF
    #OPERTORS_TO_MIRROR: comma-separated values. for example: elasticsearch-operator,cincinnati-operator,file-integrity-operator
    if [[ $OPERTORS_TO_MIRROR == "" ]]; then
        echo "mirror all operators"
    else 

        #only mirror images defined in Env OPERTORS_TO_MIRROR
        echo "    packages:">>${work_dir}/imageset-config.yaml
        for op in $(echo $OPERTORS_TO_MIRROR | tr ',' ' ' ); do
            echo "    - name: $op">>${work_dir}/imageset-config.yaml
        done
    fi
    cat ${work_dir}/imageset-config.yaml

    echo "create registry.conf"
    cat <<EOF |tee "${work_dir}/registry.conf"
[[registry]]
 location = "registry.redhat.io"
 insecure = true
 blocked = false
 mirror-by-digest-only = false
 [[registry.mirror]]
    location = "brew.registry.redhat.io"
    insecure = true
[[registry]]
 location = "registry.stage.redhat.io"
 insecure = true
 blocked = false
 mirror-by-digest-only = false
 [[registry.mirror]]
    location = "brew.registry.redhat.io"
    insecure = true
EOF
    run_command "cd $work_dir"
    run_command "oc-mirror --v1 --config ${work_dir}/imageset-config.yaml docker://${MIRROR_REGISTRY_HOST} --oci-registries-config=${work_dir}/registry.conf --continue-on-error --skip-missing --dest-skip-tls --source-skip-tls"
    echo "oc-mirror operators success"
}

# Slove: x509: certificate signed by unknown authority
# upload customzied registry ca_bundle into workers. 
# In linux: the system ca-trust directory is /etc/pki/ca-trust/source/anchors
#           openshift ca-truest file is /etc/pki/ca-trust/source/anchors/openshift-config-user-ca-bundle.crt
function set_CA_for_nodes () {
    ca_name=$(oc get image.config.openshift.io/cluster -o=jsonpath="{.spec.additionalTrustedCA.name}")
    if [ $ca_name ] && [ $ca_name = "registry-config" ] ; then
        echo "CA is ready, skip config..."
        return 0
    fi

    # get the QE additional CA
    if [[ "${SELF_MANAGED_ADDITIONAL_CA}" == "true" ]]; then
        QE_ADDITIONAL_CA_FILE="${CLUSTER_PROFILE_DIR}/mirror_registry_ca.crt"
    else
        QE_ADDITIONAL_CA_FILE="/var/run/vault/mirror-registry/client_ca.crt"
    fi

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
    echo "create ICSP or IDMS for proxy registry"
    icsp_num=$(oc get ImageContentSourcePolicy  -o name  2>/dev/null  |wc -l)
    #we registry level proxy as below.In rosa cluster, registry level proxy may be rejected. 
    #as this ICSP/IDMS is used for QE Test images quay.io/openshifttest too. We don't use oc-mirror generated ICSP or IDMS
    if [[ $icsp_num -gt 0 || $kube_minor -lt 26 ]] ; then
        cat <<EOF | oc apply -f -
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
    else
        # Create both IDMS and ITMS together for digest-based and tag-based image references
        # ITMS can coexist with IDMS (both are new APIs)
        cat <<EOF  | oc create -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: image-policy-aosqe
spec:
  imageDigestMirrors:
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
---
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: image-policy-aosqe
spec:
  imageTagMirrors:
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
    fi

    if [ $? == 0 ]; then
        if [[ $icsp_num -gt 0 || $kube_minor -lt 26 ]] ; then
            echo "create the ICSP successfully"
        else
            echo "create the IDMS and ITMS successfully"
        fi
	return 0
    else
        echo "!!! fail to create the ICSP/IDMS/ITMS"
        return 1
    fi
}

function create_catalog_sources()
{
    echo "create QE catalogsource: $CATALOGSOURCE_NAME"
    # get cluster Major.Minor version
    # since OCP 4.15, the official catalogsource use this way. OCP4.14=K8s1.27
    # details: https://issues.redhat.com/browse/OCPBUGS-31427
    if [[ ${kube_major} -gt 1 || ${kube_minor} -gt 27 ]]; then
        echo "the index image as the initContainer cache image)"
        cat <<EOF | oc create -f -
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
  image: ${mirror_index_image}
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
  image: ${mirror_index_image}
  publisher: OpenShift QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
    fi

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
        # ImagePullBackOff nothing with the imagePullSecrets
        # run_command "oc get operatorgroup -n openshift-marketplace"
        # run_command "oc get sa qe-app-registry -n openshift-marketplace -o yaml"
        # run_command "oc -n openshift-marketplace get secret $(oc -n openshift-marketplace get sa qe-app-registry -o=jsonpath='{.secrets[0].name}') -o yaml"
        run_command "oc get pods -o wide -n openshift-marketplace"
        run_command "oc -n openshift-marketplace get catalogsource $CATALOGSOURCE_NAME -o yaml"
        run_command "oc -n openshift-marketplace get pods -l olm.catalogSource=$CATALOGSOURCE_NAME -o yaml"
        node_name=$(oc -n openshift-marketplace get pods -l olm.catalogSource=$CATALOGSOURCE_NAME -o=jsonpath='{.items[0].spec.nodeName}')
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
    if [[ $? -eq 0 ]]; then
        marketplace=1
        return 0
    else
        return 1
    fi
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
              return 1
          fi
    fi
    return 0
}

#################### Main #######################################
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
        #echo "This cluster is a C2S or SC2S cluster(region us-iso-* represent C2S, us-isob-* represent SC2S), so don't use the proxy registry."
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
#
#ocp_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f1,2)
kube_major=$(oc version -o json |jq -r '.serverVersion.major')
kube_minor=$(oc version -o json |jq -r '.serverVersion.minor' | sed 's/+$//')

if [[ $OO_INDEX == "" ]];then
    origin_index_image="quay.io/openshift-qe-optional-operators/aosqe-index:v${kube_major}.${kube_minor}"
else
    origin_index_image="$OO_INDEX"
fi

mirror_index_image="${MIRROR_PROXY_REGISTRY_QUAY}/openshift-qe-optional-operators/aosqe-index:v${kube_major}.${kube_minor}"
echo "origin_index_image: ${origin_index_image}"
echo "mirror_index_image: ${mirror_index_image}"

if [ $mirror -eq 0 ]; then
    echo "Set mirror registry credential when the cluster isn't c2s or SC2S"
    set_cluster_auth || exit 1
fi
#Create ICSP for mirror registry. The ICSP are used for the following ci-opertor steps too. Abort the job if ICSP can not be created
create_settled_icsp  || exit 1

#skip the mirror or catalogsource when OLM is not enabled.
check_olm_capability || exit 0

#skip if marketplace doesn't exit
check_marketplace || exit 0

# No need to disable the default OperatorHub when marketplace disabled as default.
if [ $marketplace -eq 0 ]; then
    disable_default_catalogsource
fi

if [ $mirror -eq 1 ]; then
    echo "Mirror operator images as cluster is C2S or SC2S"
    mirror_optional_images
fi
create_catalog_sources
