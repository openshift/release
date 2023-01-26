#!/bin/bash
set -x
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

if [ "$(echo -e $CLONEREFS_OPTIONS | jq -r '.refs[] | select(.org == "openshift").repo')" == "release" ]; then
  OPERATOR_INDEX_IMAGE_REF=quay.io/redhat-developer/servicebinding-operator:index;
else
  OPERATOR_INDEX_IMAGE_REF=quay.io/redhat-developer/servicebinding-operator:pr-${PULL_NUMBER}-${PULL_PULL_SHA:0:8}-index;
fi;
make -k VERBOSE=2 OPERATOR_INDEX_IMAGE_REF=$OPERATOR_INDEX_IMAGE_REF CATSRC_NAME=sbo-pr-checks SKIP_REGISTRY_LOGIN=true EXTRA_BEHAVE_ARGS="--tags=~@crdv1beta1 --tags=~@olm-descriptors --tags=~@upgrade-with-olm --tags=~@disable-openshift-4.12 --tags=~@disable-openshift-4.8+ --tags=~@disable-openshift-4.9+ --tags=~@disable-openshift-4.10+ --tags=~@disable-openshift-4.11+ --tags=~@disable-openshift-4.12+" -o registry-login test-acceptance-with-bundle test-acceptance-artifacts
