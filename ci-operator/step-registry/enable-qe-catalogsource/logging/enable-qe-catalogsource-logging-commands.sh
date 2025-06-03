#!/bin/bash
#Description: Create catalogSources for openshift-logging operators testing. According to the environment variables set, it can create catalogSources: qe-app-registry, cluster-logging, loki-operator, elsticsearch-operator.
##Author: anli@redhat.com
#

set -u
set -e
set -o pipefail

# Indicate if cluster is updated in this script. this script wait until the updated success
CLUSTER_UPDATED=false
# Indicate if quay.io/openshift-qe-optional-operators is used
REG_QE_OPT_ENABLED=false
# Indicate if brew.registry.redhat.io is used
REG_BREW_ENABLED=false
# Indicate if registry.stage.redhat.io is used
REG_STAGE_ENABLED=false
# Indicate if konflux fbc is used.
KONFLUX_ENABLED=false

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

# Set Proxy Env, so the oc can talk with the proxy cluster 
function set_proxy () {
    if [[ -s "${SHARED_DIR}/proxy-conf.sh" ]]  ; then
        echo "# Setting the proxy"
        source "${SHARED_DIR}/proxy-conf.sh"
    fi
}

## Wait up to 30 minutes until cluster is ready if IDMS or pull-secrect is updated
function wait_cluster_ready() {
    # If no icsp,secret is updated. We needn't wait the cluster ready
    if [[ "$CLUSTER_UPDATED" == "false" ]];then
        return 0
    fi
    # The cluster upgrade may take serveral minutes to be ready
    echo "Wait up to 30 minutes until the cluster upgrade succeed"
    machineCount=$(oc get mcp worker -o=jsonpath='{.status.machineCount}')
    count=0
    while [[ $count -lt 120 ]]
    do
        echo "waiting 15s. elapsed: 15 * $count second"
        sleep 15s
	count=$(( count + 1 ))
        updatedMachineCount=$(oc get mcp worker -o=jsonpath='{.status.updatedMachineCount}')
        if [[ ${updatedMachineCount} = "${machineCount}" ]]; then
            echo "MCP updated successfully"
            break
        fi
    done
    if [[ "${updatedMachineCount}" != "${machineCount}" ]]; then
        run_command "oc get mcp,node"
        run_command "oc get mcp worker -o yaml"
	echo "Warning: the cluster is not ready in 30 minutes. the step continue with this issue"
    fi
}

# Validate if the index images are provided correctly and set correct flags 
function validate_index_image() {
    echo "# Validate if INDEX_IMAGEs are provided correctly"
    if [[ $LOGGING_INDEX_IMAGE == "" && $CLO_INDEX_IMAGE == "" && $LO_INDEX_IMAGE == ""  && $EO_INDEX_IMAGE == "" ]]; then
	echo "Skipped as no index image is specified!"
	exit 0
    fi

    if [[ $LOGGING_INDEX_IMAGE =~ registry.stage.redhat.io ||  $CLO_INDEX_IMAGE =~ registry.stage.redhat.io || $LO_INDEX_IMAGE =~ registry.stage.redhat.io || $EO_INDEX_IMAGE =~ registry.stage.redhat.io ]]; then
        REG_STAGE_ENABLED=true
    fi

    if [[ $LOGGING_INDEX_IMAGE =~ brew.registry.redhat.io.*iib ||  $CLO_INDEX_IMAGE =~ brew.registry.redhat.io.*iib || $LO_INDEX_IMAGE =~ brew.registry.redhat.io.*iib || $EO_INDEX_IMAGE =~ brew.registry.redhat.io.*iib ]]; then
        REG_STAGE_ENABLED=true
    fi

    if [[ $LOGGING_INDEX_IMAGE =~ quay.io.*aosqe-index.*konflux ||  $CLO_INDEX_IMAGE =~  quay.io.*aosqe-index.*konflux || $LO_INDEX_IMAGE =~ quay.io.*aosqe-index.*konflux || $EO_INDEX_IMAGE =~ quay.io.*aosqe-index.*konflux ]]; then
        REG_QE_OPT_ENABLED=true
        KONFLUX_ENABLED=true
    fi

    if [[ $LOGGING_INDEX_IMAGE =~ quay.io.*aosqe-index:.*[0-9]+$  || $CLO_INDEX_IMAGE =~  quay.io.*aosqe-index:.*[0-9]+$ || $LO_INDEX_IMAGE =~ quay.io.*aosqe-index:.*[0-9]+$ || $EO_INDEX_IMAGE =~ quay.io.*aosqe-index:.*[0-9]+$ ]]; then
        REG_QE_OPT_ENABLED=true
        REG_BREW_ENABLED=true
    fi

    if [[ $LOGGING_INDEX_IMAGE =~ quay.io.*fbc* ||  $CLO_INDEX_IMAGE =~  quay.io.*fbc* || $LO_INDEX_IMAGE =~ quay.io.*fbc* || $EO_INDEX_IMAGE =~ quay.io.*fbc* ]]; then
        KONFLUX_ENABLED=true
    fi

    count=0
    if [[ $REG_STAGE_ENABLED == "true"  ]]; then
	    echo "use registry.stage.redhat.io as the mirror registry"
	    count=$(( count + 1 ))
    fi

    if [[ $KONFLUX_ENABLED == "true" ]]; then
	    echo "use quay.io/redhat-user-workloads/obs-logging-tenant as the mirror registry"
	    count=$(( count + 1 ))
    fi
    if [[ $REG_BREW_ENABLED == "true" ]]; then
	    echo "use brew.registry.redhat.io as the mirror registry"
	    count=$(( count + 1 ))
    fi
    if [[ $count -gt "1" ]]; then
	    echo "Error: this step only support one mirror registry"
	    exit 1
    fi
}

# From 4.11 on, the marketplace is optional.
# That means, once the marketplace disabled, its "openshift-marketplace" project will NOT be created as default.
# But, for OLM, its global namespace still is "openshift-marketplace"(details: https://bugzilla.redhat.com/show_bug.cgi?id=2076878),
# so we need to create it manually so that optional operator teams' test cases can be run smoothly.
function validate_marketpalce() {
    echo "# validate if openshift-marketpalce can be created "
    ret=0
    oc get ns openshift-marketplace >/dev/null 2>&1 || ret=$?
    if [[ $ret -eq 0 ]]; then
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

# Update the registry credential in local and in cluster
# Note: That is the best try step, we didn't validate the credential here
function enable_registry_credential () {
    echo "# Enable registry credential "
    # get the credential saved in cluster
    oc extract secret/pull-secret -n openshift-config --confirm --to /tmp >/dev/null 2>&1 
    if [[ $ret -ne 0 ]]; then
        echo "Error: can not extract the cluster credential!"
        exit 1
    fi

     tmp_dockerconfig="/tmp/new-dockerconfigjson"
     if [[  $REG_QE_OPT_ENABLED == true ]] ;then
         reg_qe_opt_user=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.user')
         reg_qe_opt_password=$(cat "/var/run/vault/mirror-registry/registry_quay.json" | jq -r '.password')
	 reg_qe_opt_auth=$(echo -n "${reg_qe_opt_user}:${reg_qe_opt_password}" | base64 -w 0)
	 if [[ $reg_qe_opt_auth != "" ]]; then
             jq --argjson var '{"quay.io/openshift-qe-optional-operators":{"auth":"'${reg_qe_opt_auth}'","email":""}}' '.auths |= . + $var' /tmp/.dockerconfigjson > ${tmp_dockerconfig}
             mv ${tmp_dockerconfig} /tmp/.dockerconfigjson
	 fi
     fi

     if [[  $REG_BREW_ENABLED == true ]] ;then
         reg_brew_user=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.user')
         reg_brew_password=$(cat "/var/run/vault/mirror-registry/registry_brew.json" | jq -r '.password')
	 reg_brew_auth=$(echo -n "${reg_brew_user}:${reg_brew_password}" | base64 -w 0)
	 if [[ $reg_brew_auth != "" ]]; then
             jq --argjson var '{"brew.registry.redhat.io":{"auth":"'${reg_brew_auth}'","email":""}}' '.auths |= . + $var' /tmp/.dockerconfigjson > ${tmp_dockerconfig}
             mv ${tmp_dockerconfig} /tmp/.dockerconfigjson
	 fi
     fi

     if [[  $REG_STAGE_ENABLED == true ]] ;then
         reg_stage_user=$(cat "/var/run/vault/mirror-registry/registry_stage.json" | jq -r '.user')
         reg_stage_password=$(cat "/var/run/vault/mirror-registry/registry_stage.json" | jq -r '.password')
         reg_stage_auth=`echo -n "${reg_stage_user}:${reg_stage_password}" | base64 -w 0`
	 if [[ $reg_stage_auth != "" ]]; then
             jq --argjson var '{"registry.stage.redhat.io":{"auth":"'${reg_stage_auth}'","email":""}}' '.auths |= . + $var' /tmp/.dockerconfigjson > ${tmp_dockerconfig}
             mv ${tmp_dockerconfig} /tmp/.dockerconfigjson
	 fi
     fi

     # we should make the repo public instead of adding cred for quay.io/openshifttest
     #openshifttest_auth_user=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.user')
     #openshifttest_auth_password=$(cat "/var/run/vault/mirror-registry/registry_quay_openshifttest.json" | jq -r '.password')
     #openshifttest_registry_auth=`echo -n "${openshifttest_auth_user}:${openshifttest_auth_password}" | base64 -w 0`
      

     if [[ -s ${tmp_dockerconfig} ]];then
         # Update the cluster credentia
         echo "oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=${tmp_dockerconfig}"
         result=$(oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=${tmp_dockerconfig})
	 ret=$?
	 echo "${result}"
         if [[ $ret -eq 0 && ! $result =~ "pull-secret was not changed" ]]; then
                 CLUSTER_UPDATED=true
         else
             echo "oc set data secret/pull-secret failed!"
	     exit 1
         fi
     else
         echo "no secret need to be updated."
     fi
}

function create_image_mirror_set_connected() {
    echo "# Create IDMS/ICSP for cluster"
    cat <<EOF>/tmp/mirror_set_brew_clo.yaml
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-cluster-logging-operator-bundle
    source: registry.redhat.io/openshift-logging/cluster-logging-operator-bundle
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-cluster-logging-operator-bundle
    source: registry-proxy.engineering.redhat.com/rh-osbs/openshift-logging-cluster-logging-operator-bundle
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-cluster-logging-rhel9-operator
    source: registry.redhat.io/openshift-logging/cluster-logging-rhel9-operator
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-vector-rhel9
    source: registry.redhat.io/openshift-logging/vector-rhel9
  - mirrors:
    - brew.registry.redhat.io/rh-osbspenshift-logging-log-file-metric-exporter-rhel9
    source: registry.redhat.io/openshift-logging/log-file-metric-exporter-rhel9
  - mirrors:
    - brew.registry.redhat.io/rh-osbspenshift-logging-log-file-metric-exporter-rhel9
    source: registry.redhat.io/openshift-logging/log-file-metric-exporter-rhel9
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-fluentd-rhel9
    source: registry.redhat.io/openshift-logging/fluentd-rhel9
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-logging-view-plugin-rhel9
    source: registry.redhat.io/openshift-logging/logging-view-plugin-rhel9
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-eventrouter-rhel9
    source: registry.redhat.io/openshift-logging/eventrouter-rhel9
EOF

    cat <<EOF>/tmp/mirror_set_brew_lo.yaml
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-loki-operator-bundle
    source: registry.redhat.io/openshift-logging/loki-operator-bundle
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-loki-operator-bundle
    source: registry-proxy.engineering.redhat.com/rh-osbs/openshift-logging-loki-operator-bundle
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-loki-rhel9-operator
    source: registry.redhat.io/openshift-logging/loki-rhel9-operator
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-logging-loki-rhel9
    source: registry.redhat.io/openshift-logging/logging-loki-rhel9
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-lokistack-gateway-rhel9
    source: registry.redhat.io/openshift-logging/lokistack-gateway-rhel9
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-opa-openshift-rhel9
    source: registry.redhat.io/openshift-logging/opa-openshift-rhel9
EOF

    cat <<EOF>/tmp/mirror_set_brew_eo.yaml
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-elasticsearch-operator-bundle
    source: registry-proxy.engineering.redhat.com/rh-osbs/openshift-logging-elasticsearch-operator-bundle
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-elasticsearch-operator-bundle
    source: registry.redhat.io/openshift-logging/elasticsearch-operator-bundle
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-elasticsearch-rhel9-operator
    source: registry.redhat.io/openshift-logging/elasticsearch-rhel9-operator
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-elasticsearch-proxy-rhel9
    source: registry.redhat.io/openshift-logging/elasticsearch-proxy-rhel9
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-kibana6-rhel8
    source: registry.redhat.io/openshift-logging/kibana6-rhel8
  - mirrors:
    - brew.registry.redhat.io/rh-osbs/openshift-logging-logging-curator5-rhel9
    source: registry.redhat.io/openshift-logging/logging-curator5-rhel9
EOF

    cat <<EOF>/tmp/mirror_set_stage_clo.yaml
  - mirrors:
    - registry.stage.redhat.io/rh-osbs/openshift-logging-cluster-logging-operator-bundle
    source: registry.redhat.io/openshift-logging/cluster-logging-operator-bundle
  - mirrors:
    - registry.stage.redhat.io/openshift-logging/cluster-logging-rhel9-operator
    source: registry.redhat.io/openshift-logging/cluster-logging-rhel9-operator
  - mirrors:
    - registry.stage.redhat.io/openshift-logging/vector-rhel9
    source: registry.redhat.io/openshift-logging/vector-rhel9
  - mirrors:
    - registry.redhat.io/openshift-logging/log-file-metric-exporter-rhel9
    source: registry.redhat.io/openshift-logging/log-file-metric-exporter-rhel9
  - mirrors:
    - registry.redhat.io/openshift-logging/log-file-metric-exporter-rhel9
    source: registry.redhat.io/openshift-logging/log-file-metric-exporter-rhel9
  - mirrors:
    - registry.stage.redhat.io/openshift-logging/eventrouter-rhel9
    source: registry.redhat.io/openshift-logging/eventrouter-rhel9
EOF

    cat <<EOF>/tmp/mirror_set_stage_lo.yaml
  - mirrors:
    - registry.stage.redhat.io/rh-osbs/openshift-logging-loki-operator-bundle
    source: registry.redhat.io/openshift-logging/loki-operator-bundle
  - mirrors:
    - registry.stage.redhat.io/openshift-logging/loki-rhel9-operator
    source: registry.redhat.io/openshift-logging/loki-rhel9-operator
  - mirrors:
    - registry.stage.redhat.io/openshift-logging/logging-loki-rhel9
    source: registry.redhat.io/openshift-logging/logging-loki-rhel9
  - mirrors:
    - registry.stage.redhat.io/openshift-logging/lokistack-gateway-rhel9
    source: registry.redhat.io/openshift-logging/lokistack-gateway-rhel9
  - mirrors:
    - registry.stage.redhat.io/openshift-logging/opa-openshift-rhel9
    source: registry.redhat.io/openshift-logging/opa-openshift-rhel9
EOF

    cat <<EOF>/tmp/mirror_set_stage_eo.yaml
  - mirrors:
    - registry.stage.redhat.io/openshift-logging/elasticsearch-operator-bundle
    source: registry.redhat.io/openshift-logging/elasticsearch-operator-bundle
  - mirrors:
    - registry.stage.redhat.io/openshift-logging/elasticsearch-rhel9-operator
    source: registry.redhat.io/openshift-logging/elasticsearch-rhel9-operator
  - mirrors:
    - registry.stage.redhat.io/openshift-logging/elasticsearch-proxy-rhel9
    source: registry.redhat.io/openshift-logging/elasticsearch-proxy-rhel9
  - mirrors:
    - registry.stage.redhat.io/openshift-logging/kibana6-rhel8
    source: registry.redhat.io/openshift-logging/kibana6-rhel8
  - mirrors:
    - registry.stage.redhat.io/openshift-logging/logging-curator5-rhel9
    source: registry.redhat.io/openshift-logging/logging-curator5-rhel9
EOF

    cat <<EOF>/tmp/mirror_set_konflux_clo.yaml
  - mirrors:
    mirror_set_konflux_clo=" - mirrors:
    - quay.io/redhat-user-workloads/obs-logging-tenant/cluster-logging-operator-v6-3
    source: registry.redhat.io/openshift-logging/cluster-logging-rhel9-operator
  - mirrors:
    - quay.io/redhat-user-workloads/obs-logging-tenant/logging-vector-v6-3
    source: registry.redhat.io/openshift-logging/vector-rhel9
  - mirrors:
    - quay.io/redhat-user-workloads/obs-logging-tenant/log-file-metric-exporter-v6-3
    source: registry.redhat.io/openshift-logging/log-file-metric-exporter-rhel9
  - mirrors:
    - quay.io/redhat-user-workloads/obs-logging-tenant/log-file-metric-exporter-v6-3
    source: registry.redhat.io/openshift-logging/log-file-metric-exporter-rhel9
  - mirrors:
    - quay.io/redhat-user-workloads/obs-logging-tenant/logging-eventrouter-v-6-3
    source: registry.redhat.io/openshift-logging/eventrouter-rhel9
EOF

    cat <<EOF>/tmp/mirror_set_konflux_lo.yaml
  - mirrors:
    - quay.io/redhat-user-workloads/obs-logging-tenant/loki-operator-v6-3
    source: registry.redhat.io/openshift-logging/loki-rhel9-operator
  - mirrors:
    - quay.io/redhat-user-workloads/obs-logging-tenant/logging-loki-v6-3
    source: registry.redhat.io/openshift-logging/logging-loki-rhel9
  - mirrors:
    - quay.io/redhat-user-workloads/obs-logging-tenant/lokistack-gateway-v6-3
    source: registry.redhat.io/openshift-logging/lokistack-gateway-rhel9
  - mirrors:
    - quay.io/redhat-user-workloads/obs-logging-tenant/opa-openshift-v6-3
    source: registry.redhat.io/openshift-logging/opa-openshift-rhel9
EOF

    cat <<EOF>/tmp/mirror_set_konflux_eo.yaml
  - mirrors:
    - quay.io/redhat-user-workloads/obs-logging-tenant/elasticsearch-operator-5.8
    source: registry.redhat.io/openshift-logging/elasticsearch-rhel9-operator
  - mirrors:
    - quay.io/redhat-user-workloads/obs-logging-tenant/elasticsearch-proxy-5.8
    source: registry.redhat.io/openshift-logging/elasticsearch-proxy-rhel9
  - mirrors:
    - quay.io/redhat-user-workloads/obs-logging-tenant/kibana6-5.8
    source: registry.redhat.io/openshift-logging/kibana6-rhel8
  - mirrors:
    - quay.io/redhat-user-workloads/obs-logging-tenant/logging-curator5-5.8
    source: registry.redhat.io/openshift-logging/logging-curator5-rhel9
EOF

    idms_head="apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: logging-qe
spec:
  imageDigestMirrors:"

    icsp_head="apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: logging-qe
spec:
  repositoryDigestMirrors:"

    mirror_set_clo=""
    mirror_set_lo=""
    mirror_set_eo=""

    if [[ $REG_BREW_ENABLED == "true" ]]; then
	    mirror_set_clo=/tmp/mirror_set_brew_clo.yaml
	    mirror_set_lo=/tmp/mirror_set_brew_lo.yaml
	    mirror_set_eo=/tmp/mirror_set_brew_eo.yaml
    fi

    if [[ "$REG_STAGE_ENABLED" == "true" ]];then
	    mirror_set_clo=/tmp/mirror_set_stage_clo.yaml
	    mirror_set_lo=/tmp/mirror_set_stage_lo.yaml
	    mirror_set_eo=/tmp/mirror_set_stage_eo.yaml
    fi

    if [[ "$KONFLUX_ENABLED" == "true" ]];then
	    mirror_set_clo=/tmp/mirror_set_konflux_clo.yaml
	    mirror_set_lo=/tmp/mirror_set_konflux_lo.yaml
	    mirror_set_eo=/tmp/mirror_set_konflux_eo.yaml
    fi

    # Needn't create IDMS/ICSP, return 0
    if [[ $mirror_set_clo == "" && $mirror_set_clo == "" && $mirror_set_clo == "" ]]; then
        echo "skip: no ICSP/IDMS "
        return 0
    fi

    kube_minor_version=$(oc version --output=json |jq -r '.serverVersion.minor')
    # use IDMS for cluster > 4.13(kubeverion=1.26)
    if [[ "$kube_minor_version" -gt "26" ]];then
        echo "${idms_head}" >/tmp/logging-mirror-set.yaml
    else
        echo "${icsp_head}" >/tmp/logging-mirror-set.yaml
    fi


    if [[ $LOGGING_INDEX_IMAGE == "" ]]; then
        if [[ $CLO_INDEX_IMAGE != "" ]];then
            cat  $mirror_set_clo>>/tmp/logging-mirror-set.yaml
        fi
        if [[ $LO_INDEX_IMAGE != "" ]];then
            cat $mirror_set_lo>>/tmp/logging-mirror-set.yaml
        fi
        if [[ $EO_INDEX_IMAGE != "" ]];then
            cat $mirror_set_eo>>/tmp/logging-mirror-set.yaml
        fi
    else
        cat  $mirror_set_clo>>/tmp/logging-mirror-set.yaml
        cat  $mirror_set_lo>>/tmp/logging-mirror-set.yaml
        cat  $mirror_set_eo>>/tmp/logging-mirror-set.yaml
    fi

    run_command "oc apply --overwrite=true -f /tmp/logging-mirror-set.yaml"
    if [[ $? -eq "0" ]];then
       CLUSTER_UPDATED=true
    else
       echo "Error: failed to create ICSP or IDMS "
       exit 1
    fi
}

function create_catalog_source(){
    catalog_name=$1
    catalog_image=$2
    echo "create catalogsource ${catalog_name} using ${catalog_image}"
    kube_major=$(oc version -o json |jq -r '.serverVersion.major')
    kube_minor=$(oc version -o json |jq -r '.serverVersion.minor')

    #create catalogsource using catch from 4.15(1.27)
    # details: https://issues.redhat.com/browse/OCPBUGS-31427
    if [[ ${kube_major} -gt 1 || ${kube_minor} -gt 27 ]]; then
        echo "apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${catalog_name}
  namespace: openshift-marketplace
spec:
  displayName: ${catalog_name}
  grpcPodConfig:
    extractContent:
      cacheDir: /tmp/cache
      catalogDir: /configs
    memoryTarget: 30Mi
  image: ${catalog_image}
  publisher: logging QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m" >/tmp/logging-catalog.yaml
    else
        echo "apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${catalog_name}
  namespace: openshift-marketplace
spec:
  displayName: ${catalog_name}
  image: ${catalog_image}
  publisher: Logging QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m" >/tmp/logging-catalog.yaml
    fi

    run_command "oc apply --overwrite=true -f /tmp/logging-catalog.yaml"
}

function create_catalog_sources_connected()
{   echo "# Create catalog sources"
    catalog_sources=""
    if [[ $LOGGING_INDEX_IMAGE != "" ]]; then
         create_catalog_source "qe-app-registry" ${LOGGING_INDEX_IMAGE}
	 catalog_sources="$catalog_sources qe-app-registry" 
    fi

    if [[ $CLO_INDEX_IMAGE != "" ]]; then
         create_catalog_source "cluster-logging" ${CLO_INDEX_IMAGE}
	 catalog_sources="$catalog_sources cluster-logging" 
    fi
    if [[ $LO_INDEX_IMAGE != "" ]]; then
         create_catalog_source "loki-operator" ${LO_INDEX_IMAGE}
	 catalog_sources="$catalog_sources loki-operator" 
    fi
    if [[ $EO_INDEX_IMAGE != "" ]]; then
         create_catalog_source "elasticsearch-operator" ${EO_INDEX_IMAGE}
	 catalog_sources="$catalog_sources elasticsearch-operator" 
    fi
    

    ## Wait until all catalogsource pod in running status
    #  The step fail if the catalog can not be ready in given time(5minutes)
    echo "Wait up to 5 minutes unilt all catalogsources are ready"
    tmp_catalogsources=""
    count=0
    while [ $count -lt 60 ]
    do
        echo "waiting 5s, elasped: 5 * ${count} second"
        sleep 5s
	count=$(( count + 1 ))
	tmp_catalogsources=""
	for catalog in ${catalog_sources}; do
            STATUS=$(oc -n openshift-marketplace get catalogsource $catalog -o=jsonpath="{.status.connectionState.lastObservedState}")
            if [[ $STATUS != "READY" ]]; then
                 tmp_catalogsources="${tmp_catalogsources} ${catalog}"
            fi
	 done
	 catalog_sources=${tmp_catalogsources}
	 if [[ ${catalog_sources// /} == "" ]];then
             break
         fi
    done

    if [[ ${catalog_sources// /} != ""  ]];then
        echo "Error: catalogsource ${catalog_sources} are not ready in given time"
        run_command "oc -n openshift-marketplace get pods -o wide"
	for catalog in ${catalog_sources}; do
	    run_command "oc -n openshift-marketplace get pods -l catalogsource.operators.coreos.com/update=${catalog} -o jsonpath={.items[].status}"
	done

        run_command "oc get mcp,node"
        run_command "oc get mcp worker -o yaml"
        run_command "oc get mc $(oc get mcp/worker --no-headers | awk '{print $2}') -o=jsonpath={.spec.config.storage.files}|jq '.[] | select(.path==\"/var/lib/kubelet/config.json\")'"
	exit 1
    fi 
}

#############Main ##############################
echo "# Enable-qe-catalogsource start"
set_proxy
validate_index_image
validate_marketpalce
enable_registry_credential
create_image_mirror_set_connected
wait_cluster_ready
create_catalog_sources_connected

echo "# Enable-qe-catalogsource end"
