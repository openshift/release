#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#env vars
QUAYREGISTRY=${QUAYREGISTRY}
QUAYNAMESPACE=${QUAYNAMESPACE}
BUILDERIMAGE=${QUAY_BUILDER_IMAGE}

echo "Deploy Quay virtual builder, unmanaged TLS is prerequisite"

#In Prow, base domain is longer, like: ci-op-w3ki37mj-cc978.qe.devcluster.openshift.com
ocp_base_domain_name=$(oc get dns/cluster -o jsonpath="{.spec.baseDomain}")
echo "Base domain name: $ocp_base_domain_name"

quay_builder_route="${QUAYREGISTRY}-quay-builder-${QUAYNAMESPACE}.apps.$ocp_base_domain_name"
echo "Quay builder route: $quay_builder_route"

temp_dir=$(mktemp -d)

#Create a new project for virtual builders
function create_virtual_builders() {
    oc new-project virtual-builders
    oc create sa -n virtual-builders quay-builder
    oc adm policy -n virtual-builders add-role-to-user edit system:serviceaccount:virtual-builders:quay-builder
    oc adm policy -n virtual-builders add-scc-to-user anyuid -z quay-builder

    #ocp 4.11+
    token=$(oc create token quay-builder -n virtual-builders --duration 24h)
    echo $token
    # if [ -e "$temp_dir"/ssl.cert ]; then
    #     echo "Create the TLS/SSL cert file successfully"
    # else
    #     echo "!!! Fail to create the TLS/SSL cert file "
    #     return 1
    # fi
    echo "virtual builder successfully created"
}

function generate_builder_yaml() {
    cat >>"$temp_dir"/config_builder.yaml <<EOF
FEATURE_BUILD_SUPPORT: true
BUILDMAN_HOSTNAME: ${quay_builder_route}:443
BUILD_MANAGER:
- ephemeral
- ALLOWED_WORKER_COUNT: 20 
  ORCHESTRATOR_PREFIX: buildman/production/
  ORCHESTRATOR:
    REDIS_HOST: quayregistry-quay-redis
    REDIS_PASSWORD: ""
    REDIS_SSL: false
    REDIS_SKIP_KEYSPACE_EVENT_SETUP: false
  EXECUTORS:
  - EXECUTOR: kubernetesPodman
    DEBUG: true
    NAME: openshift
    BUILDER_NAMESPACE: virtual-builders 
    SETUP_TIME: 180
    QUAY_USERNAME: 'quay-username'
    QUAY_PASSWORD: quay-password
    BUILDER_CONTAINER_IMAGE: ${BUILDERIMAGE}
    # Kubernetes resource options
    K8S_API_SERVER: api.$ocp_base_domain_name:6443
    K8S_API_TLS_CA: /conf/stack/extra_ca_certs/build_cluster.crt
    VOLUME_SIZE: 8G
    KUBERNETES_DISTRIBUTION: openshift
    CONTAINER_MEMORY_LIMITS: 1G 
    CONTAINER_CPU_LIMITS: 1000m
    CONTAINER_MEMORY_REQUEST: 1G 
    CONTAINER_CPU_REQUEST: 500m
    NODE_SELECTOR_LABEL_KEY: ""
    NODE_SELECTOR_LABEL_VALUE: ""
    SERVICE_ACCOUNT_NAME: quay-builder 
    SERVICE_ACCOUNT_TOKEN: "$token"
EOF
}

function copy_builder_config() {
    #Copy builder config file to SHARED_DIR
    echo "Copy builder config file $SHARED_DIR folder"
    cp "$temp_dir"/config_builder.yaml "$SHARED_DIR"
    cat "$temp_dir"/config_builder.yaml

    #Clean up temp dir
    # rm -rf "$temp_dir" || true
}

#Get openshift CA Cert, include into secret bundle
create_virtual_builders || true
generate_builder_yaml

#Finally Copy builder config file to SHARED_DIR
trap copy_builder_config EXIT
