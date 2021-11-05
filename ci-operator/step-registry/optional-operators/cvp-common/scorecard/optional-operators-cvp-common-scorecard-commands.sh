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

  CUSTOM_SERVICE_ACCOUNT=$(/usr/local/bin/yq r "${OPERATOR_DIR}/tests/scorecard/config.yaml" 'serviceaccount')
  if [ "${CUSTOM_SERVICE_ACCOUNT}" != "" ] && [ "${CUSTOM_SERVICE_ACCOUNT}" != "null" ]; then
    echo "Creating service account ${CUSTOM_SERVICE_ACCOUNT} for usage wih the custom scorecard"
    oc create serviceaccount "${CUSTOM_SERVICE_ACCOUNT}" -n "${NAMESPACE}"
    oc create clusterrolebinding default-sa-crb --clusterrole=cluster-admin --serviceaccount="${NAMESPACE}":"${CUSTOM_SERVICE_ACCOUNT}"
  fi

  echo "Running the operator-sdk scorecard test using the custom, bundle-provided configuration, json output and storing it in the artifacts directory"
  # Runs the custom scorecard tests using the user-provided configuration
  # The wait-time is set higher to allow for long/complex custom tests, should be kept under 1h to not exceed pipeline max time
  operator-sdk scorecard \
    --namespace="${NAMESPACE}" \
    --kubeconfig "${KUBECONFIG}" \
    --output json \
    --wait-time 3000s \
    "${OPERATOR_DIR}" > "${ARTIFACT_DIR}"/scorecard-output-custom.json || true
fi
