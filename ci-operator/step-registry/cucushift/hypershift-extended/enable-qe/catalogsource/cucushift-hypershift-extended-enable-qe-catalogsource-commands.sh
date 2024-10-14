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

function create_catalog_sources() {
    # get cluster Major.Minor version
    kube_major=$(oc version -o json |jq -r '.serverVersion.major')
    kube_minor=$(oc version -o json |jq -r '.serverVersion.minor' | sed 's/+$//')
    index_image="quay.io/openshift-qe-optional-operators/aosqe-index:v${kube_major}.${kube_minor}"

    if [ "${DISCONNECTED}" = "true" ]; then
        MIRROR_REGISTRY_HOST=`head -n 1 "${SHARED_DIR}/mirror_registry_url"`
        # the proxy registry port 6001 for quay.io
        MIRROR_PROXY_REGISTRY_QUAY=`echo "${MIRROR_REGISTRY_HOST}" | sed 's/5000/6001/g' `
        index_image="${MIRROR_PROXY_REGISTRY_QUAY}/openshift-qe-optional-operators/aosqe-index:v${kube_major}.${kube_minor}"
    fi

    echo "create QE catalogsource: qe-app-registry"
    cat <<EOF | oc create -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: qe-app-registry
  namespace: openshift-marketplace
spec:
  displayName: Production Operators
  image: ${index_image}
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
        echo "!!! fail to create QE CatalogSource"
        # ImagePullBackOff nothing with the imagePullSecrets
        # run_command "oc get operatorgroup -n openshift-marketplace"
        # run_command "oc get sa qe-app-registry -n openshift-marketplace -o yaml"
        # run_command "oc -n openshift-marketplace get secret $(oc -n openshift-marketplace get sa qe-app-registry -o=jsonpath='{.secrets[0].name}') -o yaml"

        run_command "oc get pods -o wide -n openshift-marketplace"
        run_command "oc -n openshift-marketplace get catalogsource qe-app-registry -o yaml"
        run_command "oc -n openshift-marketplace get pods -l olm.catalogSource=qe-app-registry -o yaml"
        return 1
    fi
    set -e
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