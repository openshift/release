#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

function vars {
    AZURE_TENANT="$(<"/var/run/aro-v4-e2e-prow-spn/tenant")"
    export AZURE_TENANT
    AZURE_SUBSCRIPTION_ID="$(<"/var/run/aro-v4-e2e-prow-spn/subscription")"
    export AZURE_SUBSCRIPTION_ID
    AZURE_CLIENT_ID="$(<"/var/run/aro-v4-e2e-prow-spn/appId")"
    export AZURE_CLIENT_ID
    AZURE_CLIENT_NAME="$(<"/var/run/aro-v4-e2e-prow-spn/displayName")"
    export AZURE_CLIENT_NAME
    AZURE_SECRET="$(<"/var/run/aro-v4-e2e-prow-spn/password")"
    export AZURE_SECRET
    export ANSIBLE_VERBOSITY=${ANSIBLE_VERBOSITY:-0}
    export AZURE_CLUSTER_RESOURCE_GROUP="prow-${JOB_NAME_SAFE}-${AZURE_LOCATION}"
    export AZURE_CLUSTER_NAME="aro-e2e"
}

function verify {
    if [[ -z "${AZURE_SUBSCRIPTION_ID}" ]]; then
        echo ">> AZURE_SUBSCRIPTION_ID is not set"
        exit 1
    fi

    if [[ -z "${AZURE_LOCATION}" ]]; then
        echo ">> AZURE_LOCATION is not set"
        exit 1
    fi

    if [[ -z "${ANSIBLE_CLUSTER_PATTERN}" ]]; then
        echo ">> ANSIBLE_CLUSTER_PATTERN is not set"
        exit 1
    fi
}

function login {
  az login --service-principal --username "$AZURE_CLIENT_ID" --password "$AZURE_SECRET" --tenant "$AZURE_TENANT"
  az account show -o yaml
}

function get-oc-client {
    OC_URL="$(az aro show -n "${AZURE_CLUSTER_NAME}" -g "${AZURE_CLUSTER_RESOURCE_GROUP}" \
      -o tsv --query consoleProfile.url | \
      sed 's/console-openshift-console/downloads-openshift-console/')amd64/linux/oc.tar"
    echo "Downloading oc client from ${OC_URL}"
    wget -q -O /tmp/oc.tar "${OC_URL}"
    tar -xvf /tmp/oc.tar -C /tmp/
    export PATH="/tmp:${PATH}"
}

function run-tests {
    export APISERVER_CERT="${SHARED_DIR}/${AZURE_CLUSTER_NAME}-${AZURE_CLUSTER_RESOURCE_GROUP}-apiserver.crt"
    echo Using kubeconfig "${KUBECONFIG}" with certificate authority "${APISERVER_CERT}"
    oc --certificate-authority="${APISERVER_CERT}" version
    oc --certificate-authority="${APISERVER_CERT}" get nodes -o wide
    oc --certificate-authority="${APISERVER_CERT}" get co
    oc --certificate-authority="${APISERVER_CERT}" get cluster.aro/cluster -o yaml
    oc --certificate-authority="${APISERVER_CERT}" adm must-gather --dest-dir "${ARTIFACT_DIR}/gather-openshift" ||:
    echo Testing Server CA: "${APISERVER_CERT}"
}

vars
verify
login
get-oc-client
run-tests

