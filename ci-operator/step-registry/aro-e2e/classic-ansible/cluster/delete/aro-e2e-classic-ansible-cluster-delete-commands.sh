#!/bin/bash

set -x
set -o nounset
set -o errexit
set -o pipefail

CERT="${SHARED_DIR}/dev-client.pem"

function vars {
    export AZURE_TENANT="$(<"/var/run/aro-v4-e2e-prow-spn/tenant")"
    export AZURE_SUBSCRIPTION_ID="$(<"/var/run/aro-v4-e2e-prow-spn/subscription")"
    export AZURE_CLIENT_ID="$(<"/var/run/aro-v4-e2e-prow-spn/appId")"
    export AZURE_CLIENT_NAME="$(<"/var/run/aro-v4-e2e-prow-spn/displayName")"
    export AZURE_SECRET="$(<"/var/run/aro-v4-e2e-prow-spn/password")"
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

function delete-cluster {
    echo "Deleting cluster"
    unset AZURE_SUBSCRIPTION_ID # to force ansible to use the logged in creds
    ansible-playbook -i "${SHARED_DIR}/hosts.yaml" \
        -e "location=${AZURE_LOCATION}" \
        -e "CLEANUP=True" \
        cleanup.playbook.yaml
}

vars
verify
login
delete-cluster
