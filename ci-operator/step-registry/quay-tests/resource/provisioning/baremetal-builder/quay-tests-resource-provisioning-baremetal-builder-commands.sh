#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

QUAYREGISTRY=${QUAYREGISTRY}
QUAYNAMESPACE=${QUAYNAMESPACE}
BUILDERIMAGE=${QUAY_BUILDER_IMAGE}
WORKERIMAGE=${QUAY_BUILDER_WORKER_IMAGE}
WORKERTAG=${QUAY_BUILDER_WORKER_TAG}

KONFLUX_PULL_USER=$(cat /var/run/konflux-quay-pull-auth/username)
KONFLUX_PULL_PASS=$(cat /var/run/konflux-quay-pull-auth/password)

echo "Deploy Quay bare-metal QEMU builder, unmanaged tls is prerequisite"

ocp_base_domain_name=$(oc get dns/cluster -o jsonpath="{.spec.baseDomain}")
echo "Base domain name: $ocp_base_domain_name"

quay_builder_route="${QUAYREGISTRY}-quay-builder-${QUAYNAMESPACE}.apps.$ocp_base_domain_name"
echo "Quay builder route: $quay_builder_route"

temp_dir=$(mktemp -d)

function create_virtual_builders() {
    oc new-project virtual-builders
    oc create sa -n virtual-builders quay-builder
    oc adm policy -n virtual-builders add-role-to-user edit system:serviceaccount:virtual-builders:quay-builder
    oc adm policy -n virtual-builders add-scc-to-user anyuid -z quay-builder
    oc adm policy -n virtual-builders add-scc-to-user privileged -z quay-builder

    token=$(oc create token quay-builder -n virtual-builders --duration 24h)
    if [ -z "$token" ]; then
        echo "!!! Fail to create virtual builder"
        return 1
    else
        echo "Virtual builder successfully created"
    fi
}

function create_builder_pull_secret() {
    echo "Creating image pull secret in virtual-builders namespace"

    KONFLUX_REGISTRY="image-rbac-proxy.apps.stone-prd-rh01.pg1f.p1.openshiftapps.com"

    set +x
    oc create secret docker-registry builder \
        -n virtual-builders \
        --docker-server="${KONFLUX_REGISTRY}" \
        --docker-username="${KONFLUX_PULL_USER}" \
        --docker-password="${KONFLUX_PULL_PASS}" || true

    oc secrets link -n virtual-builders quay-builder builder --for=pull || true
    set -x

    echo "Image pull secret created and linked to quay-builder SA"
}

function generate_builder_yaml() {
    set +x
    cat >>"$temp_dir"/config_builder.yaml <<EOF
FEATURE_BUILD_SUPPORT: true
BUILDMAN_HOSTNAME: ${quay_builder_route}:443
BUILD_MANAGER:
- ephemeral
- ALLOWED_WORKER_COUNT: 20
  ORCHESTRATOR_PREFIX: buildman/production/
  ORCHESTRATOR:
    REDIS_HOST: ${QUAYREGISTRY}-quay-redis
    REDIS_PASSWORD: ""
    REDIS_SSL: false
    REDIS_SKIP_KEYSPACE_EVENT_SETUP: false
  EXECUTORS:
  - EXECUTOR: kubernetes
    DEBUG: true
    NAME: openshift
    BUILDER_NAMESPACE: virtual-builders
    SETUP_TIME: 180
    MINIMUM_RETRY_THRESHOLD: 0
    BUILDER_VM_CONTAINER_IMAGE: ${BUILDERIMAGE}
    WORKER_IMAGE: ${WORKERIMAGE}
    WORKER_TAG: ${WORKERTAG}
    CONTAINER_RUNTIME: podman
    VERIFY_TLS: false
    IMAGE_PULL_SECRET_NAME: builder
    K8S_API_SERVER: api.$ocp_base_domain_name:6443
    K8S_API_TLS_CA: /conf/stack/extra_ca_certs/build_cluster.crt
    VOLUME_SIZE: 32G
    VM_MEMORY_LIMIT: 4G
    KUBERNETES_DISTRIBUTION: openshift
    CONTAINER_MEMORY_LIMITS: 5120Mi
    CONTAINER_CPU_LIMITS: 1000m
    CONTAINER_MEMORY_REQUEST: 3968Mi
    CONTAINER_CPU_REQUEST: 500m
    NODE_SELECTOR_LABEL_KEY: ""
    NODE_SELECTOR_LABEL_VALUE: ""
    SERVICE_ACCOUNT_NAME: quay-builder
    SERVICE_ACCOUNT_TOKEN: $token
EOF
    set -x
}

function copy_builder_config() {
    echo "Copy builder config file $SHARED_DIR folder"
    cp "$temp_dir"/config_builder.yaml "$SHARED_DIR"

    rm -rf "$temp_dir"
}

create_virtual_builders || true
create_builder_pull_secret
generate_builder_yaml

trap copy_builder_config EXIT
