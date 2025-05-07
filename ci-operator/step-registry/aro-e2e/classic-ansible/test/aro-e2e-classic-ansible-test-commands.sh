#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

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

function make-ansible-inventory {
    echo "Creating ansible inventory"
    tee "/tmp/hosts.yaml" << EOF
---
standard_clusters:
    hosts:
        e2e:
            cluster_name: "${AZURE_CLUSTER_NAME}"
            resource_group: "${AZURE_CLUSTER_RESOURCE_GROUP}"
            network_prefix_cidr: 10.0.0.0/22
            master_cidr: 10.0.0.0/23
            master_vm_size: Standard_D8s_v3
            worker_cidr: 10.0.2.0/23
            worker_vm_size: Standard_D4s_v3
            vnet_enable_encryption: true
            vnet_encryption_enforcement_policy: AllowUnencrypted
            create_csp: true
EOF
}

function get-oc-client {
    OC_URL="$(az aro show -n "${AZURE_CLUSTER_NAME}" -g "${AZURE_CLUSTER_RESOURCE_GROUP}" \
      -o tsv --query consoleProfile.url | \
      sed 's/console-openshift-console/downloads-openshift-console/')amd64/linux/oc.tar"
    echo "Downloading oc client from ${OC_URL}"
    wget -O /tmp/oc.tar "${OC_URL}"
    tar -xvf /tmp/oc.tar -C /tmp/
    ls -laR /tmp
    export PATH="/tmp:${PATH}"
}

function run-tests {
    echo Using kubeconfig: "${KUBECONFIG}"
    oc --insecure-skip-tls-verify version
    oc --insecure-skip-tls-verify get nodes -o wide
    oc --insecure-skip-tls-verify get co
    oc --insecure-skip-tls-verify get cluster.aro/cluster -o yaml
    oc --insecure-skip-tls-verify adm must-gather --dest-dir "${ARTIFACT_DIR}/gather-openshift" ||:
    APISERVER_CERT="${SHARED_DIR}/${AZURE_CLUSTER_NAME}-${AZURE_CLUSTER_RESOURCE_GROUP}-apiserver.crt"
    echo Testing Server CA: "${APISERVER_CERT}"
    oc --certificate-authority="${APISERVER_CERT}" version ||:
}

ls -laR "/tmp" "${SHARED_DIR}/" "${ARTIFACT_DIR}/" ||:
vars
verify
login
make-ansible-inventory
get-oc-client
run-tests

