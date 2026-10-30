#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#env vars
QUAYREGISTRY=${QUAYREGISTRY}
QUAYNAMESPACE=${QUAYNAMESPACE}
QUAY_BUILDER_EXECUTOR=${QUAY_BUILDER_EXECUTOR:-kubernetesPodman}
case "${QUAY_BUILDER_EXECUTOR}" in
  kubernetesPodman|kubernetes) ;;
  *) echo "ERROR: QUAY_BUILDER_EXECUTOR must be kubernetesPodman or kubernetes, got '${QUAY_BUILDER_EXECUTOR}'" >&2; exit 1 ;;
esac

#credentials
QUAY_USERNAME=$(cat /var/run/quay-qe-quaybuilder-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quaybuilder-secret/password)

echo "Deploy Quay virtual builder, unmanaged tls is prerequisite"

#In Prow, base domain is longer, like: ci-op-w3ki37mj-cc978.qe.devcluster.openshift.com
ocp_base_domain_name=$(oc get dns/cluster -o jsonpath="{.spec.baseDomain}")
echo "Base domain name: $ocp_base_domain_name"

quay_builder_route="${QUAYREGISTRY}-quay-builder-${QUAYNAMESPACE}.apps.$ocp_base_domain_name"
echo "Quay builder route: $quay_builder_route"
quay_route="${QUAYREGISTRY}-quay-${QUAYNAMESPACE}.apps.$ocp_base_domain_name"

temp_dir=$(mktemp -d)

#Create a new project for virtual builders
function create_virtual_builders() {
    oc new-project virtual-builders
    oc create sa -n virtual-builders quay-builder
    oc adm policy -n virtual-builders add-role-to-user edit system:serviceaccount:virtual-builders:quay-builder
    oc adm policy -n virtual-builders add-scc-to-user anyuid -z quay-builder

    #ocp 4.11+
    token=$(oc create token quay-builder -n virtual-builders --duration 24h)
    # echo $token
    if [ -z "$token" ]; then
        echo "!!! Fail to create virtual builder"
        return 1
    else
        echo "Virtual builder successfully created"
    fi
    
}

# The kubernetes executor boots each build in a qemu-kvm VM started with
# -enable-kvm and no software fallback (quay-builder-qemu start.sh), and its Job
# has no node selector, so every worker needs /dev/kvm. Record it and fail fast.
function probe_kvm() {
    local out="${ARTIFACT_DIR}/kvm-probe.txt" node missing=0
    oc get nodes -l node-role.kubernetes.io/worker -L node.kubernetes.io/instance-type >"$out"
    for node in $(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); do
        echo "== ${node}" >>"$out"
        oc debug "node/${node}" -- chroot /host sh -c 'test -c /dev/kvm && ls -l /dev/kvm' >>"$out" 2>&1 || missing=1
    done
    cat "$out"
    if [ "$missing" -ne 0 ]; then
        echo "ERROR: QUAY_BUILDER_EXECUTOR=kubernetes needs /dev/kvm on every worker; see kvm-probe.txt" >&2
        return 1
    fi
}

function generate_builder_yaml() {
    cat >>"$temp_dir"/config_builder.yaml <<EOF
FEATURE_BUILD_SUPPORT: true
BUILDMAN_HOSTNAME: ${quay_builder_route}:443
BUILD_MANAGER:
- ephemeral
- ALLOWED_WORKER_COUNT: 20
  ORCHESTRATOR_PREFIX: buildman/production/
  # Per RH Quay docs: if unset/too low the ephemeral worker can fail to register
  # ("Invalid build token: Signature has expired") and the build never leaves the
  # build-scheduled phase. Docs recommend >= 240; use the reference value 3600.
  JOB_REGISTRATION_TIMEOUT: 3600
  ORCHESTRATOR:
    REDIS_HOST: ${QUAYREGISTRY}-quay-redis
    REDIS_PASSWORD: ""
    REDIS_SSL: false
    REDIS_SKIP_KEYSPACE_EVENT_SETUP: false
  EXECUTORS:
EOF
    if [ "${QUAY_BUILDER_EXECUTOR}" = "kubernetes" ]; then
        generate_qemu_executor_yaml
        return
    fi
    cat >>"$temp_dir"/config_builder.yaml <<EOF
  - EXECUTOR: kubernetesPodman
    DEBUG: true
    NAME: openshift
    BUILDER_NAMESPACE: virtual-builders 
    SETUP_TIME: 180
    MINIMUM_RETRY_THRESHOLD: 0
    QUAY_USERNAME: "${QUAY_USERNAME}"
    QUAY_PASSWORD: ${QUAY_PASSWORD}
    # The quay-deploy-* step replaces from-csv with the installed CSV's
    # RELATED_IMAGE_COMPONENT_BUILDER.
    BUILDER_CONTAINER_IMAGE: from-csv
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
    SERVICE_ACCOUNT_TOKEN: $token
EOF
}

# The VM has no cluster pull secret or mirror config: it logs in to
# WORKER_IMAGE's registry with QUAY_USERNAME/QUAY_PASSWORD and runs
# WORKER_IMAGE:WORKER_TAG. The Job pod carries those values in its env, so they
# are a throwaway user of the Quay under test: quay-deploy-aws-s3 creates it and
# copies the CSV's RELATED_IMAGE_COMPONENT_BUILDER to WORKER_IMAGE.
function generate_qemu_executor_yaml() {
    local worker_user=qemubuilder worker_password
    worker_password=$(set +o pipefail; LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 24)
    cat >>"$temp_dir"/config_builder.yaml <<EOF
  - EXECUTOR: kubernetes
    # DEBUG skips the VM's poweroff and the Job's deletion, so every VM would
    # keep running and count against ALLOWED_WORKER_COUNT.
    DEBUG: false
    NAME: openshift
    BUILDER_NAMESPACE: virtual-builders
    # Time to boot the VM, pull WORKER_IMAGE and register.
    SETUP_TIME: 600
    MINIMUM_RETRY_THRESHOLD: 0
    QUAY_USERNAME: ${worker_user}
    QUAY_PASSWORD: "${worker_password}"
    WORKER_IMAGE: ${quay_route}/${worker_user}/quay-builder
    WORKER_TAG: ci
    CONTAINER_RUNTIME: podman
    # The quay-deploy-* step replaces from-csv-qemu with the installed CSV's
    # RELATED_IMAGE_COMPONENT_BUILDER_QEMU and pre-pulls it on every worker.
    BUILDER_VM_CONTAINER_IMAGE: from-csv-qemu
    IMAGE_PULL_POLICY: IfNotPresent
    K8S_API_SERVER: api.$ocp_base_domain_name:6443
    K8S_API_TLS_CA: /conf/stack/extra_ca_certs/build_cluster.crt
    VOLUME_SIZE: 8G
    KUBERNETES_DISTRIBUTION: openshift
    # The VM runs with -smp 2 and 4G of memory (VM_MEMORY_LIMIT default).
    CONTAINER_MEMORY_LIMITS: 5120Mi
    CONTAINER_CPU_LIMITS: 2000m
    CONTAINER_MEMORY_REQUEST: 3968Mi
    CONTAINER_CPU_REQUEST: 1000m
    NODE_SELECTOR_LABEL_KEY: ""
    NODE_SELECTOR_LABEL_VALUE: ""
    SERVICE_ACCOUNT_NAME: quay-builder
    SERVICE_ACCOUNT_TOKEN: $token
EOF
}

function copy_builder_config() {
    #Copy builder config file to SHARED_DIR
    echo "Copy builder config file $SHARED_DIR folder"
    cp "$temp_dir"/config_builder.yaml "$SHARED_DIR"
    # cat "$temp_dir"/config_builder.yaml
    # sleep 600

    #Clean up temp dir
    rm -rf "$temp_dir"
}

#Get openshift CA Cert, include into secret bundle
create_virtual_builders || true
if [ "${QUAY_BUILDER_EXECUTOR}" = "kubernetes" ]; then
    oc adm policy -n virtual-builders add-scc-to-user privileged -z quay-builder
    probe_kvm
fi
generate_builder_yaml

#Finally Copy builder config file to SHARED_DIR
trap copy_builder_config EXIT
