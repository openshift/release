#!/bin/bash

set -e
set -u
set -o pipefail

# Error handling function
function handle_error() {
    echo "Error occurred in $1"
    exit 1
}

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function check_if_hypershift_env () {
    if [ -f "${SHARED_DIR}/nested_kubeconfig" ]; then
        IS_HYPERSHIFT_ENV="yes"
    else
        # We must set IS_HYPERSHIFT_ENV="no" otherwise OCP CI will fail because this script sets "set -u".
        IS_HYPERSHIFT_ENV="no"
        return 0
    fi
    MC_KUBECONFIG_FILE="${SHARED_DIR}/hs-mc.kubeconfig"
    if [ -f "${MC_KUBECONFIG_FILE}" ]; then
        export KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
    elif [ -f "${SHARED_DIR}/mgmt_kubeconfig" ]; then
        export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
    else
        export KUBECONFIG="${SHARED_DIR}/kubeconfig"
    fi

    HYPERSHIFT_NAMESPACE=$(oc get hostedclusters -A -ojsonpath="{.items[?(@.metadata.name==\"$(cat ${SHARED_DIR}/cluster-name)\")].metadata.namespace}")
    count=$(oc get hostedclusters --no-headers --ignore-not-found -n "$HYPERSHIFT_NAMESPACE" | wc -l)
    echo "hostedcluster count: $count"
    if [ "$count" -lt 1 ]  ; then
        echo "namespace clusters don't have hostedcluster"
        exit 1
    fi
    # Limitation: we always & only select the first hostedcluster to add idp-htpasswd. "
    cluster_name=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
}

function set_common_variables () {
    if [ "$IS_HYPERSHIFT_ENV" == "yes" ]; then
        # In some HyperShift CI, the namespace of hostedcluster is local-cluster instead of clusters.
        MIDDLE_NAMESPACE="$HYPERSHIFT_NAMESPACE"
        TARGET_RESOURCE="hostedcluster/$cluster_name -n $MIDDLE_NAMESPACE"
        KAS_NAMESPACE="$MIDDLE_NAMESPACE-$cluster_name"
        OIDC_PROVIDERS_UPPER_FIELD='.spec.configuration.authentication'
	CLUSTER_IN_TEST="${SHARED_DIR}/nested_kubeconfig"
    else
        MIDDLE_NAMESPACE="openshift-config"
        TARGET_RESOURCE="authentication.config/cluster"
        KAS_NAMESPACE="openshift-kube-apiserver"
        OIDC_PROVIDERS_UPPER_FIELD='.spec'
	CLUSTER_IN_TEST="${SHARED_DIR}/kubeconfig"
    fi
}

function configure_external_oidc () {
    CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | grep -Eo '^4\.[0-9]+')
    FEATURE_SET=$(oc get featuregate cluster -o jsonpath='{.spec.featureSet}')
    if [ "$IS_HYPERSHIFT_ENV" == "no" ] && [ "$CLUSTER_VERSION" == "4.19" ] && [ "$FEATURE_SET" != "TechPreviewNoUpgrade" ]; then
        echo "OCP 4.19 env must be TechPreviewNoUpgrade in order to configure external OIDC authentication!"
        exit 1
    fi
    [ "$IS_HYPERSHIFT_ENV" == "yes" ] && OLD_GEN=$(oc get deployment/kube-apiserver -n "$KAS_NAMESPACE" -o jsonpath='{.metadata.generation}')

    OIDC_PROVIDERS_UPPER_FIELD=$(echo '{}' | jq "$OIDC_PROVIDERS_UPPER_FIELD = $(< $SHARED_DIR/oidcProviders.json)")
    [ "$IS_HYPERSHIFT_ENV" == "no" ] && OIDC_PROVIDERS_UPPER_FIELD=$(jq '.spec.webhookTokenAuthenticator = null' <<< "$OIDC_PROVIDERS_UPPER_FIELD")
    oc apply -f "$SHARED_DIR"/oidcProviders-secret-configmap.yaml -n "$MIDDLE_NAMESPACE"

    # This step can be applied in both OCP CI jobs and HyperShift hosted cluster CI jobs.
    # Note: for HyperShift hosted cluster CI jobs, oidcProviders must be configured in day-1. The corresponding workflow is
    # "cucushift-hypershift-extended-external-oidc-guest", which configures hardcode Entra ID oidcProviders in the rendered
    # hostedcluster manifest in day-1.
    # So, to cover other oidc providers' tests for hosted cluster CI jobs, the step here uses day-2 operation to
    # replace original Entra ID with other providers, considering no good way to configure any provider in that workflow.
    # Don't quote the $TARGET_RESOURCE variable because it may include spaces
    oc patch $TARGET_RESOURCE --type=merge -p="$OIDC_PROVIDERS_UPPER_FIELD"

    if [ "$IS_HYPERSHIFT_ENV" == "no" ]; then 
        if ! oc wait co/kube-apiserver --for=condition=Progressing --timeout=100s; then
            echo "Timeout waiting co/kube-apiserver to be Progressing=true"
	    oc get po -n openshift-kube-apiserver -L revision -l apiserver
	    oc get co/kube-apiserver
	    exit 1
	fi
        if ! oc wait co/kube-apiserver --for=condition=Progressing=false --timeout=1200s; then
            echo "Timeout waiting co/kube-apiserver to be Progressing=false"
	    oc get po -n openshift-kube-apiserver -L revision -l apiserver
	    oc get co/kube-apiserver
	    exit 1
	fi
    else
        EXPECTED_REPLICAS=$(oc get deployment/kube-apiserver -n "$KAS_NAMESPACE" -o jsonpath='{.spec.replicas}')
        timeout 15m bash -c "while true; do
            AVAILABLE_REPLICAS=$(oc get deployment/kube-apiserver  -n $KAS_NAMESPACE -o jsonpath='{.status.availableReplicas}')
            NEW_GEN=$(oc get deployment/kube-apiserver  -n $KAS_NAMESPACE -o jsonpath='{.metadata.generation}')
            oc get pods -n $KAS_NAMESPACE | grep -e NAME -e kube-apiserver && echo
            if [[ $EXPECTED_REPLICAS == $AVAILABLE_REPLICAS && $NEW_GEN != $OLD_GEN ]]; then
                break
            else
                sleep 10
            fi
        done
        " || { echo "Timeout waiting deployment/kube-apiserver in $KAS_NAMESPACE to complete rollout"; exit 1; }
    fi
    echo "KAS completed rollout"

    IS_GOOD_STATUS="yes"
    # Below cluster operators should be in good status
    if oc get co kube-apiserver authentication console --no-headers --kubeconfig "$CLUSTER_IN_TEST" | grep -v "True  *False  *False"; then
        echo '"oc get co kube-apiserver authentication console" shows some cluster operator not in good status!'
        IS_GOOD_STATUS="no"
    fi
    # Below covers regression bugs like OCPBUGS-60219 in case the clusterversion is not in good status
    if oc get clusterversion version --kubeconfig "$CLUSTER_IN_TEST" | grep -iE "(err|warn|fail|bad|not available)"; then
        echo '"oc get clusterversion version" shows not good status! The ".status.conditions" shows:'
        oc get clusterversion version -o jsonpath='{.status.conditions}' --kubeconfig "$CLUSTER_IN_TEST"
        IS_GOOD_STATUS="no"
    fi
    if [ "$IS_GOOD_STATUS" != "yes" ]; then
        exit 1
    fi
}

if [ -f "${SHARED_DIR}/cluster-type" ] ; then
    CLUSTER_TYPE=$(cat "${SHARED_DIR}/cluster-type")
    if [[ "$CLUSTER_TYPE" == "osd" ]] || [[ "$CLUSTER_TYPE" == "rosa" ]]; then
        echo "Skip the step. The managed clusters generate the testing accounts by themselves"
        exit 0
    fi
fi

# Main script execution with error handling
if [ ! -f "$SHARED_DIR"/oidcProviders.json ] || [ ! -f "$SHARED_DIR"/oidcProviders-secret-configmap.yaml ]; then
    echo "The oidcProviders.json and oidcProviders-secret-configmap.yaml fiels must be provided by a previous step!"
    exit 1
fi
set_proxy || handle_error "set_proxy"
check_if_hypershift_env || handle_error "check_if_hypershift_env"
set_common_variables || handle_error "set_common_variables"
configure_external_oidc || handle_error "configure_external_oidc"
