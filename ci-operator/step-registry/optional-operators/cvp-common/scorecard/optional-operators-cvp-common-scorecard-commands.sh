#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

OPENSHIFT_AUTH="${OPENSHIFT_AUTH:-/var/run/brew-pullsecret/.dockerconfigjson}"
SCORECARD_CONFIG="${SCORECARD_CONFIG:-/tmp/config/scorecard-basic-config.yml}"

# Steps for running the basic operator-sdk scorecard test
# Expects the standard Prow environment variables to be set and
# the brew proxy registry credentials to be mounted

NAMESPACE=$(grep "install_namespace:" "${SHARED_DIR}"/oo_deployment_details.yaml | cut -d ':' -f2 | xargs)

pushd "${ARTIFACT_DIR}"
OPERATOR_DIR="test-operator"

echo "Starting the basic operator-sdk scorecard test for ${BUNDLE_IMAGE}"

echo "Extracting the operator bundle image into the operator directory"
mkdir -p "${OPERATOR_DIR}"
pushd "${OPERATOR_DIR}"
oc image extract "${BUNDLE_IMAGE}" --confirm -a "${OPENSHIFT_AUTH}"
chmod -R go+r ./
popd
echo "Extracted the following bundle data:"
tree "${OPERATOR_DIR}"

echo "Running the operator-sdk scorecard test using the basic configuration, json output and storing it in the artifacts directory"
operator-sdk scorecard --config "${SCORECARD_CONFIG}" \
                       --namespace "${NAMESPACE}" \
                       --kubeconfig "${KUBECONFIG}" \
                       --output json \
                       "${OPERATOR_DIR}" > "${ARTIFACT_DIR}"/scorecard-output-basic.json || true

if [ -f "${OPERATOR_DIR}/tests/scorecard/config.yaml" ]; then
  echo "CUSTOM SCORECARD TESTS DETECTED"
  echo "Running the operator-sdk scorecard test using the custom, bundle-provided configuration, json output and storing it in the artifacts directory"
  operator-sdk scorecard \
    --namespace=${NAMESPACE} \
    --kubeconfig ${KUBECONFIG} \
    --output json \
    "${OPERATOR_DIR}" > "${ARTIFACT_DIR}"/scorecard-output-custom.json || true
fi
