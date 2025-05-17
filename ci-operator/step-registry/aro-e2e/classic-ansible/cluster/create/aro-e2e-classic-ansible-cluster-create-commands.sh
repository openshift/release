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
    cat ${SHARED_DIR}/azure-login.sh
    chmod +x ${SHARED_DIR}/azure-login.sh
    source ${SHARED_DIR}/azure-login.sh
    whoami ||:
    id ||:
    az account show -o yaml ||:
    ls -laR $HOME/.azure ||:
    set ||:
}

function create-cluster {
    echo "Creating cluster"
    export ANSIBLE_VERBOSITY=1
    unset AZURE_SUBSCRIPTION_ID # to force ansible to use the logged in creds
    ansible-playbook -i hosts.yaml \
        -l "${ANSIBLE_CLUSTER_PATTERN}" \
        -e "location=${AZURE_LOCATION}" \
        -e "CLUSTERPREFIX=aro-ci" \
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
create-cluster
get-kubeconfig
