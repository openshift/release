#!/bin/bash

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

  if [[ -z "${ANSIBLE_CLUSTER_PREFIX}" ]]; then
      echo ">> ANSIBLE_CLUSTER_PREFIX is not set"
      exit 1
  fi
}

function login {
  chmod +x ${SHARED_DIR}/azure-login.sh
  source ${SHARED_DIR}/azure-login.sh
}

function get-e2e {
    git clone https://github.com/openshift/aro-e2e --depth 0
}

function create-cluster {
    pushd aro-e2e
    echo "Creating ansible image"
    make ansible-image
    echo "Deleting cluster"
    make cluster-cleanup \
        LOCATION=${AZURE_LOCATION} \
        CLUSTERPREFIX=${AZURE_CLUSTER_PREFIX} \
        CLUSTERPATTERN=${ANSIBLE_CLUSTER_PATTERN} \
        CLEANUP=True \
        ANSIBLE_VERBOSITY=1
    popd
}

# for saving files...
cd /tmp

vars
verify
login
delete-cluster
