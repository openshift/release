#!/bin/bash

set -e
set -u
set -o pipefail

function timestamp() {
    date -u --rfc-3339=seconds
}

function run_command() {
    local cmd="$1"
    echo "Running Command: ${cmd}"
    eval "${cmd}"
}

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "Setting proxy configuration..."
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "No proxy settings found. Skipping proxy configuration..."
    fi
}

function wait_for_state() {
    local object="$1"
    local state="$2"
    local timeout="$3"
    local namespace="${4:-}"
    local selector="${5:-}"

    echo "Waiting for '${object}' in namespace '${namespace}' with selector '${selector}' to exist..."
    for _ in {1..30}; do
        oc get ${object} --selector="${selector}" -n=${namespace} |& grep -ivE "(no resources found|not found)" && break || sleep 5
    done

    echo "Waiting for '${object}' in namespace '${namespace}' with selector '${selector}' to become '${state}'..."
    oc wait --for=${state} --timeout=${timeout} ${object} --selector="${selector}" -n="${namespace}"
    return $?
}

function subscribe_operator () {
    echo "Checking if the PackageManifests exist in the CatalogSource before installing the operators..."
    
    # Check for cert-manager operator
    cert_manager_output=$(oc get packagemanifest -n openshift-marketplace -l=catalog=$CATSRC_NAME --field-selector=metadata.name=openshift-cert-manager-operator 2>&1)
    if [[ $? -ne 0 ]] || echo "$cert_manager_output" | grep -q "No resources found"; then
        echo "No cert-manager PackageManifest found. Skipping cert-manager installation..."
    else
        echo "Installing cert-manager operator..."
        oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator-og
  namespace: cert-manager-operator
spec:
  targetNamespaces: []
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  name: openshift-cert-manager-operator
  source: $CATSRC_NAME
  sourceNamespace: openshift-marketplace
EOF

        if wait_for_state "deployment/cert-manager-operator-controller-manager" "condition=Available" "5m" "cert-manager-operator"; then
            echo "Cert-manager operator is ready"
        else
            echo "Timed out waiting for cert-manager operator. Dumping resources for debugging..."
            run_command "oc get pod -n cert-manager-operator"
            run_command "oc get event -n cert-manager-operator"
            exit 1
        fi
    fi

    # Check for kueue operator
    kueue_output=$(oc get packagemanifest -n openshift-marketplace -l=catalog=$CATSRC_NAME --field-selector=metadata.name=kueue-operator 2>&1)
    if [[ $? -ne 0 ]] || echo "$kueue_output" | grep -q "No resources found"; then
        echo "No kueue PackageManifest found. Skipping kueue installation..."
        exit 0
    fi

    if [[ "$TARGET_NAMESPACES" == "!all" ]]; then
        TARGET_NAMESPACES=""
    fi

    echo "Creating the Namespace, OperatorGroup and Subscription for the kueue operator installation..."
    oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-kueue-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kueue-operator-group
  namespace: openshift-kueue-operator
spec:
  targetNamespaces: [$TARGET_NAMESPACES]
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kueue-operator
  namespace: openshift-kueue-operator
spec:
  channel: $CHANNEL
  name: kueue-operator
  source: $CATSRC_NAME
  sourceNamespace: openshift-marketplace
EOF

    if wait_for_state "deployment/openshift-kueue-operator" "condition=Available" "5m" "openshift-kueue-operator"; then
        echo "Kueue operator is ready"        
        installedCSV=$(oc get subscription kueue-operator -n openshift-kueue-operator -o jsonpath='{.status.installedCSV}')
        run_command "oc get csv $installedCSV -n openshift-kueue-operator"
        run_command "oc get csv $installedCSV -n openshift-kueue-operator -o=jsonpath='{.spec.relatedImages}'"
        echo
    fi

    # Wait for Kueue CRD to be available
    if wait_for_state "crd/kueues.kueue.openshift.io" "condition=Established" "2m" "" ""; then
        echo "Kueue CRD is established"
    else
        echo "Timed out waiting for Kueue CRD. Dumping resources for debugging..."
        run_command "oc get crd | grep kueue"
        exit 1
    fi

    # Wait for openshift-kueue-operator pod to be ready
    echo "Waiting for openshift-kueue-operator pod to be ready..."
    if wait_for_state "pod" "condition=Ready" "5m" "openshift-kueue-operator" "name=openshift-kueue-operator"; then
        echo "openshift-kueue-operator pod is ready"
    fi
}

if [ -s "${SHARED_DIR}/catsrc_name" ]; then
    echo "Loading the catalog source name to use from the '${SHARED_DIR}/catsrc_name'..."
    CATSRC_NAME=$(cat "${SHARED_DIR}"/catsrc_name)
fi

timestamp
set_proxy
subscribe_operator

echo "[$(timestamp)] Succeeded in installing the kueue Operator for Red Hat OpenShift!" 