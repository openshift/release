#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Install SBO from `redhat-operators` catalog source
export CATSRC_NAME=redhat-operators
export OPERATOR_CHANNEL=stable
export OPERATOR_PACKAGE=rh-service-binding-operator
export SKIP_REGISTRY_LOGIN=true

./install.sh 

# Execute Acceptance Tests
export TEST_ACCEPTANCE_START_SBO=remote
export EXTRA_BEHAVE_ARGS="--tags=~@crdv1beta1 --tags=~@olm-descriptors --tags=~@upgrade-with-olm --tags=~@disable-openshift-4.12 --tags=~@disable-openshift-4.8+ --tags=~@disable-openshift-4.9+ --tags=~@disable-openshift-4.10+ --tags=~@disable-openshift-4.11+ --tags=~@disable-openshift-4.12+"

make -k VERBOSE=2 -o registry-login test-acceptance test-acceptance-artifacts
