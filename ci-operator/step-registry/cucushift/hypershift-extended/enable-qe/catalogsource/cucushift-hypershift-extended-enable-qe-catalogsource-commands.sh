#!/bin/bash

set -e
set -u
set -o pipefail
set -x

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
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
function wait_for_catalogsource() {
    local namespace=$1
    local name=$2

    set +e
    COUNTER=0
    while [ $COUNTER -lt 600 ]
    do
        sleep 20
        COUNTER=`expr $COUNTER + 20`
        echo "waiting ${COUNTER}s"
        STATUS=`oc -n "$namespace" get catalogsource "$name" -o=jsonpath="{.status.connectionState.lastObservedState}"`
        if [[ $STATUS = "READY" ]]; then
            echo "create catalogsource $name successfully"
            break
        fi
    done
    if [[ $STATUS != "READY" ]]; then
        echo "!!! fail to create CatalogSource $name"
        run_command "oc get pods -o wide -n $namespace"
        run_command "oc -n $namespace get catalogsource $name -o yaml"
        run_command "oc -n $namespace get pods -l olm.catalogSource=$name -o yaml"
        return 1
    fi
    set -e

}
function create_catalog_sources() {
    # get cluster Major.Minor version
    kube_major=$(oc version -o json |jq -r '.serverVersion.major')
    kube_minor=$(oc version -o json |jq -r '.serverVersion.minor' | sed 's/+$//')

    if [ "${DISCONNECTED}" = "true" ]; then
        index_image="$(sed 's/5000/6001/' "${SHARED_DIR}/mirror_registry_url")/openshift-qe-optional-operators/aosqe-index:v${kube_major}.${kube_minor}"
    else
        index_image="quay.io/openshift-qe-optional-operators/aosqe-index:v${kube_major}.${kube_minor}"
    fi
    index_image_repo="${index_image%:*}"

    echo "create QE catalogsource: qe-app-registry"
    cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: qe-app-registry
  namespace: openshift-marketplace
  annotations:
    olm.catalogImageTemplate: "${index_image_repo}:v{kube_major_version}.{kube_minor_version}"
spec:
  displayName: Production Operators
  image: ${index_image}
  publisher: OpenShift QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
    wait_for_catalogsource "openshift-marketplace" "qe-app-registry"
}

function create_catalog_source_for_netobserv() {
    catalogsource_namespace="openshift-netobserv-operator"
    catalogsource_name="netobserv-konflux-fbc"
    echo "create QE catalogsource: $catalogsource_name in namespace: $catalogsource_namespace"

cat <<EOF | oc create -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: netobserv
spec:
  imageDigestMirrors:
    - mirrors:
      - quay.io/redhat-user-workloads/ocp-network-observab-tenant/network-observability-operator-ystream
      - quay.io/redhat-user-workloads/ocp-network-observab-tenant/network-observability-operator-zstream
      source: registry.redhat.io/network-observability/network-observability-rhel9-operator
    - mirrors:
      - quay.io/redhat-user-workloads/ocp-network-observab-tenant/flowlogs-pipeline-ystream
      - quay.io/redhat-user-workloads/ocp-network-observab-tenant/flowlogs-pipeline-zstream
      source: registry.redhat.io/network-observability/network-observability-flowlogs-pipeline-rhel9
    - mirrors:
      - quay.io/redhat-user-workloads/ocp-network-observab-tenant/netobserv-ebpf-agent-ystream
      - quay.io/redhat-user-workloads/ocp-network-observab-tenant/netobserv-ebpf-agent-zstream
      source: registry.redhat.io/network-observability/network-observability-ebpf-agent-rhel9
    - mirrors:
      - quay.io/redhat-user-workloads/ocp-network-observab-tenant/network-observability-console-plugin-ystream
      - quay.io/redhat-user-workloads/ocp-network-observab-tenant/network-observability-console-plugin-zstream
      source: registry.redhat.io/network-observability/network-observability-console-plugin-rhel9
    - mirrors:
      - quay.io/redhat-user-workloads/ocp-network-observab-tenant/network-observability-cli-ystream
      - quay.io/redhat-user-workloads/ocp-network-observab-tenant/network-observability-cli-zstream
      source: registry.redhat.io/network-observability/network-observability-cli-rhel9
    - mirrors:
      - quay.io/redhat-user-workloads/ocp-network-observab-tenant/network-observability-operator-bundle-ystream
      - quay.io/redhat-user-workloads/ocp-network-observab-tenant/network-observability-operator-bundle-zstream
      source: registry.redhat.io/network-observability/network-observability-operator-bundle
    - mirrors:
        - quay.io/redhat-user-workloads/ocp-network-observab-tenant/network-observability-console-plugin-pf4-ystream
      source: registry.redhat.io/network-observability/network-observability-console-plugin-compat-rhel9
EOF

      cat <<EOF | oc create -f -
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    openshift.io/cluster-monitoring: "true"
  name: $catalogsource_namespace
EOF

    cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $catalogsource_name
  namespace: $catalogsource_namespace
spec:
  displayName: NetObserv Konflux
  image: quay.io/redhat-user-workloads/ocp-network-observab-tenant/catalog-ystream:latest
  publisher: NetObserv QE
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF
    wait_for_catalogsource "$catalogsource_namespace" "$catalogsource_name"
}

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

if [[ $SKIP_HYPERSHIFT_PULL_SECRET_UPDATE == "true" ]]; then
  echo "SKIP ....."
  exit 0
fi

if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
  exit 1
fi

echo "enable qe catalogsource"
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"

check_marketplace
create_catalog_sources
create_catalog_source_for_netobserv
