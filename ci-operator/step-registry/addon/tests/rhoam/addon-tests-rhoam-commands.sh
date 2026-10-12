#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

OC_HOST=$(oc whoami --show-server)
OCP_PASSWORD=$(cat "${KUBEADMIN_PASSWORD_FILE}")

export OPENSHIFT_HOST=${OC_HOST}
export OPENSHIFT_PASSWORD=${OCP_PASSWORD}
export MULTIAZ="false"
export DESTRUCTIVE="false"
export NUMBER_OF_TENANTS="2"
export TENANTS_CREATION_TIMEOUT="3"
export OUTPUT_DIR=${ARTIFACT_DIR}

# running RHOAM testsuite
./setup_external.sh
