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

function delete-cluster {
    echo "Deleting cluster"
    unset AZURE_SUBSCRIPTION_ID # to force ansible to use the logged in creds
    ansible-playbook -i "/tmp/hosts.yaml" \
        -e "location=${AZURE_LOCATION}" \
        -e "CLEANUP=True" \
        cleanup.playbook.yaml
}

vars
verify
login
make-ansible-inventory
delete-cluster
