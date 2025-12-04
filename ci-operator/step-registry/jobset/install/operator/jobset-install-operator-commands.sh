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
    local max_retries=6
    local retry_interval=20
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        output=$(oc get packagemanifest -n openshift-marketplace -l=catalog=$CATSRC_NAME --field-selector=metadata.name=jobset-operator 2>&1)
        if [[ $? -eq 0 ]] && ! echo "$output" | grep -q "No resources found"; then
            echo "PackageManifest found, proceeding with installation..."
            break
        fi
        
        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $max_retries ]]; then
            echo "PackageManifest not found, retrying in $retry_interval seconds... (attempt $retry_count of $max_retries)"
            sleep $retry_interval
        else
            echo "No PackageManifest found after $max_retries attempts. Skipping installation..."
            exit 0
        fi
    done

    if [[ "$TARGET_NAMESPACES" == "!all" ]]; then
        TARGET_NAMESPACES=""
    fi

    echo "Creating the Namespace, OperatorGroup and Subscription for the operator installation..."
    oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: jobset-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: jobset-operator-og
  namespace: jobset-operator
spec:
  targetNamespaces: [$TARGET_NAMESPACES]
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: jobset-operator
  namespace: jobset-operator
spec:
  channel: $CHANNEL
  name: jobset-operator
  source: $CATSRC_NAME
  sourceNamespace: openshift-marketplace
EOF

    if wait_for_state "deployment/jobset-operator-controller-manager" "condition=Available" "5m" "jobset-operator"; then
        echo "Operator is ready"        
        installedCSV=$(oc get subscription jobset-operator -n jobset-operator -o jsonpath='{.status.installedCSV}')
        run_command "oc get csv $installedCSV -n jobset-operator"
        run_command "oc get csv $installedCSV -n jobset-operator -o=jsonpath='{.spec.relatedImages}'"
        echo
    else
        echo "Timed out after 5m. Dumping resources for debugging..."
        run_command "oc get pod -n jobset-operator"
        run_command "oc get event -n jobset-operator"
        run_command "oc get csv -n jobset-operator"
        run_command "oc get subscription jobset-operator -n jobset-operator -o=yaml"
        run_command "oc get event -n openshift-marketplace | grep jobset"
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

echo "[$(timestamp)] Succeeded in installing the Jobset Operator!"
