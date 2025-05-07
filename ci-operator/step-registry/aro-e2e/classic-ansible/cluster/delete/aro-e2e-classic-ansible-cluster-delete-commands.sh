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
}

function delete-cluster {
    echo "Deleting cluster"
    pushd /ansible
    ansible-playbook -i hosts.yaml \
        -l "${ANSIBLE_CLUSTER_PATTERN}" \
        -e "location=${AZURE_LOCATION}" \
        -e "CLUSTERPREFIX=${AZURE_CLUSTER_RESOURCE_GROUP}" \
        -e "ANSIBLE_VERBOSITY=1" \
        -e "CLEANUP=True" \
        cleanup.playbook.yaml
    popd
}

# for saving files...
cd /tmp

vars
verify
login
delete-cluster
