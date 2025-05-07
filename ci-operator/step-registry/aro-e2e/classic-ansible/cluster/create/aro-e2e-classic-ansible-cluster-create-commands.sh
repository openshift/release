#!/bin/bash

set -x
set -o nounset
set -o errexit
set -o pipefail

CERT="${SHARED_DIR}/dev-client.pem"

function vars {
  source ${SHARED_DIR}/vars.sh
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
    sed -i 's/--password/--certificate/g' ${SHARED_DIR}/azure-login.sh
    chmod +x "${SHARED_DIR}/azure-login.sh"
    source "${SHARED_DIR}/azure-login.sh"
    az account show -o yaml
    ls -laR "${CLUSTER_PROFILE_DIR}"
}

function make-ansible-inventory {
    echo "Creating ansible inventory"
    CSP_CLIENTID="$(<"${CLUSTER_PROFILE_DIR}/sp_id")"
    CSP_CLIENTSECRET="$(<"${CLUSTER_PROFILE_DIR}/sp_password")"
    CSP_OBJECTID="$(<"${CLUSTER_PROFILE_DIR}/sp_objectid")"
    tee "/tmp/hosts.yaml" << EOF
---
standard_clusters:
    hosts:
        e2e:
            name: "${JOB_NAME_SAFE}"
            resource_group: "${JOB_NAME}"
            network_prefix_cidr: 10.0.0.0/22
            master_cidr: 10.0.0.0/23
            master_vm_size: Standard_D8s_v3
            worker_cidr: 10.0.2.0/23
            worker_vm_size: Standard_D4s_v3
            vnet_enable_encryption: true
            vnet_encryption_enforcement_policy: AllowUnencrypted
            create_csp: false
            csp_info:
                appId: "${CSP_CLIENTID}"
                password: "${CSP_CLIENTSECRET}"
EOF
}

function create-cluster {
    echo "Creating cluster"
    export ANSIBLE_VERBOSITY=1
    unset AZURE_SUBSCRIPTION_ID # to force ansible to use the logged in creds
    ansible-playbook -i "/tmp/hosts.yaml" \
        -e "location=${AZURE_LOCATION}" \
        -e "CLEANUP=False" \
        deploy.playbook.yaml
}

function get-kubeconfig {
    echo "Getting cluster kubeconfig"
    az aro get-admin-kubeconfig -n aro -g ${AZURE_CLUSTER_RESOURCE_GROUP}-${CLUSTERPATTERN} -f /tmp/kubeconfig
}

vars
verify
login
make-ansible-inventory
create-cluster
get-kubeconfig
