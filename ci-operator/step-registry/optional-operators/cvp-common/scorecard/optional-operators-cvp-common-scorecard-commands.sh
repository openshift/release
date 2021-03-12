#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Steps for running the basic operator-sdk scorecard test
# Expects the standard Prow environment variables to be set and
# the brew proxy registry credentials to be mounted


NAMESPACE=$(grep "install_namespace:" ${SHARED_DIR}/oo_deployment_details.yaml | cut -d ':' -f2 | xargs)

OPERATOR_DIR="${ARTIFACT_DIR}/test-operator-basic"

echo "Starting the basic operator-sdk scorecard test for ${BUNDLE_IMAGE}"

echo "Extracting the operator bundle image into the operator directory"
mkdir -p ${OPERATOR_DIR}
pushd ${OPERATOR_DIR}
oc image extract ${BUNDLE_IMAGE} --confirm -a /var/run/brew-pullsecret/dockercfg.json
popd
echo "Extracted the following bundle data:"
tree ${OPERATOR_DIR}

echo "Running the operator-sdk scorecard test using the basic configuration, json output and storing it in the artifacts directory"
operator-sdk scorecard --config /tmp/config/scorecard-basic-config.yml \
                       --namespace ${NAMESPACE} \
                       --kubeconfig ${KUBECONFIG} \
                       --output json \
                       ${OPERATOR_DIR} > ${ARTIFACT_DIR}/scorecard-output-basic.json
