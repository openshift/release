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
    echo "Checking if the PackageManifest exists in the CatalogSource before installing the operator..."
    output=$(oc get packagemanifest -n openshift-marketplace -l=catalog=$CATSRC_NAME --field-selector=metadata.name=openshift-cert-manager-operator 2>&1)
    if [[ $? -ne 0 ]] || echo "$output" | grep -q "No resources found"; then
        echo "No PackageManifest found. Skipping installation..."
        exit 0
    fi

    if [[ "$TARGET_NAMESPACES" == "!all" ]]; then
        TARGET_NAMESPACES=""
    fi

    echo "Creating the Namespace, OperatorGroup and Subscription for the operator installation..."
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
  targetNamespaces: [$TARGET_NAMESPACES]
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: $CHANNEL
  name: openshift-cert-manager-operator
  source: $CATSRC_NAME
  sourceNamespace: openshift-marketplace
EOF

    if wait_for_state "deployment/cert-manager-operator-controller-manager" "condition=Available" "5m" "cert-manager-operator"; then
        echo "Operator is ready"        
        installedCSV=$(oc get subscription openshift-cert-manager-operator -n cert-manager-operator -o jsonpath='{.status.installedCSV}')
        run_command "oc get csv $installedCSV -n cert-manager-operator"
        run_command "oc get csv $installedCSV -n cert-manager-operator -o=jsonpath='{.spec.relatedImages}'"
        echo
    else
        echo "Timed out after 5m. Dumping resources for debugging..."
        run_command "oc get pod -n cert-manager-operator"
        run_command "oc get event -n cert-manager-operator"
        run_command "oc get csv -n cert-manager-operator"
        run_command "oc get subscription openshift-cert-manager-operator -n cert-manager-operator -o=yaml"
        run_command "oc get event -n openshift-marketplace | grep cert-manager"
        exit 1
    fi

    if wait_for_state "deployment/cert-manager" "condition=Available" "5m" "cert-manager" && \
        wait_for_state "deployment/cert-manager-webhook" "condition=Available" "5m" "cert-manager" && \
        wait_for_state "deployment/cert-manager-cainjector" "condition=Available" "5m" "cert-manager"; then
        echo "Operands are all ready"
    else
        echo "Timed out after 5m. Dumping resources for debugging..."
        run_command "oc get pod -n cert-manager"
        run_command "oc get event -n cert-manager"
        exit 1
    fi
}

if [ -s "${SHARED_DIR}/catsrc_name" ]; then
    echo "Loading the catalog source name to use from the '${SHARED_DIR}/catsrc_name'..."
    CATSRC_NAME=$(cat "${SHARED_DIR}"/catsrc_name)
fi

timestamp
set_proxy
subscribe_operator

echo "[$(timestamp)] Succeeded in installing the cert-manager Operator for Red Hat OpenShift!"
