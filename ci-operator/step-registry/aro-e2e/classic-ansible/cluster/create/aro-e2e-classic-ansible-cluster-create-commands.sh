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

function make-ssh-key {
    echo "Creating ssh key"
    ssh-keygen -t rsa -b 4096 -f "${SHARED_DIR}/aro-e2e" -N ""
    export SSH_CONFIG_DIR="${SHARED_DIR}/"
    export SSH_KEY_BASENAME=aro-e2e
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

function create-cluster {
    echo "Creating cluster"
    unset AZURE_SUBSCRIPTION_ID # to force ansible to use the logged in creds
    ansible-playbook -i "/tmp/hosts.yaml" \
        -e "location=${AZURE_LOCATION}" \
        -e "CLEANUP=False" \
        -e "SSH_KEY_BASENAME=${SSH_KEY_BASENAME}" \
        -e "SSH_CONFIG_DIR=${SSH_CONFIG_DIR}" \
        -e "STATE_DIR=${SHARED_DIR}" \
        deploy.playbook.yaml
}

function get-kubeconfig {
    echo "Getting cluster kubeconfig to ${KUBECONFIG}"
    az aro get-admin-kubeconfig -n "${AZURE_CLUSTER_NAME}" -g "${AZURE_CLUSTER_RESOURCE_GROUP}" -f "${KUBECONFIG}"
}

function save-shared-files {
    ls -la /tmp "${SHARED_DIR}/"
    cp -v "${KUBECONFIG}" "${SHARED_DIR}/kubeconfig"
    cp -v "/tmp/${AZURE_CLUSTER_NAME}-${AZURE_CLUSTER_RESOURCE_GROUP}.kubeconfig" "${SHARED_DIR}"
    cp -v "/tmp/${AZURE_CLUSTER_NAME}-${AZURE_CLUSTER_RESOURCE_GROUP}-apiserver.crt" "${SHARED_DIR}"
    cp -v "/tmp/oc-${AZURE_CLUSTER_NAME}-${AZURE_CLUSTER_RESOURCE_GROUP}" "${ARTIFACT_DIR}/oc" ||:
}

vars
verify
login
make-ssh-key
make-ansible-inventory
create-cluster
get-kubeconfig
save-shared-files
