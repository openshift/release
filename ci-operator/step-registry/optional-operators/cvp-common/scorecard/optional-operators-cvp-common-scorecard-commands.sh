#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Runs the supplied command until the non-empty output file is created
# or retries_max is reached.
# Takes 2 arguments - the command/function and the output file
run_scorecard() {
  
  # try to the run tests for the first time to generate the file
  "$1" "$2"
  local max_retries=6
  # Define a counter for the number of retries
  local retries=1
  search_string="timed out waiting for the condition"
  # Keep searching for the string in the file until it is not found
  while grep -q "$search_string" "$2" && [ $retries -ne $max_retries ]; do
      echo "[$(date --utc +%FT%T.%3NZ)] Retrying for scorecard test: Attempt $retries of $max_retries"
      retries=$((retries + 1))
      # sleep for 10 seconds
      sleep 10
      "$1" "$2"
  done
}

# Runs the basic scorecard tests using the prepared scorecard config
# Takes 1 argument as the output file for the scorecard command
basic_tests() {
  local OUTPUT_FILE=$1
  operator-sdk scorecard --config "${SCORECARD_CONFIG}" \
                       --namespace "${NAMESPACE}" \
                       --kubeconfig "${KUBECONFIG}" \
                       --verbose \
                       --output json \
                       --wait-time 60s \
                       --pod-security "restricted" \
                       "${OPERATOR_DIR}" > "${OUTPUT_FILE}" || true
}

# Runs the custom scorecard using the config in the operator bundle image
# Takes 1 argument as the output file for the scorecard command
# If the CUSTOM_SCORECARD_TESTCASE is set, runs in single test case mode:
#    Outputs the results in xunit format and stores them in the ARTIFACT_DIR
#    Uses the selector option to execute just a single test from the config
custom_tests() {
  local OUTPUT_FILE=$1
  ADDITIONAL_OPTIONS=""
  if [[ -n "${CUSTOM_SCORECARD_TESTCASE}" && "${TEST_MODE}" == "msp" ]]; then
    ADDITIONAL_OPTIONS="--test-output ${ARTIFACT_DIR} --selector=test=${CUSTOM_SCORECARD_TESTCASE}"
  fi
  operator-sdk scorecard \
      --namespace="${NAMESPACE}" \
      --kubeconfig "${KUBECONFIG}" \
      --verbose \
      --output "${CUSTOM_SCORECARD_OUTPUT_FORMAT}" \
      --wait-time 3000s \
      --pod-security "restricted" \
      ${ADDITIONAL_OPTIONS} \
      --service-account "${SCORECARD_SERVICE_ACCOUNT}" \
      "${OPERATOR_DIR}" > "${OUTPUT_FILE}" || true
}

BREW_DOCKERCONFIGJSON=${BREW_DOCKERCONFIGJSON:-'/var/run/brew-pullsecret/.dockerconfigjson'}

echo "[$(date --utc +%FT%T.%3NZ)] BREW_DOCKERCONFIGJSON=${BREW_DOCKERCONFIGJSON}"

OPENSHIFT_AUTH="${OPENSHIFT_AUTH:-$BREW_DOCKERCONFIGJSON}"
echo "[$(date --utc +%FT%T.%3NZ)] OPENSHIFT_AUTH=${OPENSHIFT_AUTH}"

SCORECARD_CONFIG="${SCORECARD_CONFIG:-/tmp/config/scorecard-basic-config.yml}"
echo "[$(date --utc +%FT%T.%3NZ)] SCORECARD_CONFIG=${SCORECARD_CONFIG}"

CUSTOM_SCORECARD_TESTCASE="${CUSTOM_SCORECARD_TESTCASE:-''}"
echo "[$(date --utc +%FT%T.%3NZ)] CUSTOM_SCORECARD_TESTCASE=${CUSTOM_SCORECARD_TESTCASE}"

# Steps for running the basic operator-sdk scorecard test
# Expects the standard Prow environment variables to be set and
# the brew proxy registry credentials to be mounted

NAMESPACE=$(grep "install_namespace:" "${SHARED_DIR}"/oo_deployment_details.yaml | cut -d ':' -f2 | xargs)
echo "[$(date --utc +%FT%T.%3NZ)] NAMESPACE=${NAMESPACE}"

pushd "${ARTIFACT_DIR}"
OPERATOR_DIR="test-operator"
echo "[$(date --utc +%FT%T.%3NZ)] OPERATOR_DIR=${OPERATOR_DIR}"

echo "[$(date --utc +%FT%T.%3NZ)] Starting the basic operator-sdk scorecard test for ${BUNDLE_IMAGE}"
echo "[$(date --utc +%FT%T.%3NZ)] Extracting the operator bundle image into the operator directory"
mkdir -p "${OPERATOR_DIR}"
pushd "${OPERATOR_DIR}"

oc image extract "${BUNDLE_IMAGE}" --confirm -a "${OPENSHIFT_AUTH}"
chmod -R go+r ./
popd
echo "[$(date --utc +%FT%T.%3NZ)] Extracted the following bundle data:"
tree "${OPERATOR_DIR}"

echo "[$(date --utc +%FT%T.%3NZ)] Running the operator-sdk scorecard test using the basic configuration, json output and storing it in the artifacts directory"
run_scorecard basic_tests "${ARTIFACT_DIR}"/scorecard-output-basic.json

IS_CUSTOM_SERVICE_ACCOUNT_CREATED=${IS_CUSTOM_SERVICE_ACCOUNT_CREATED:-false}
if [ -f "${OPERATOR_DIR}/tests/scorecard/config.yaml" ]; then
  echo "[$(date --utc +%FT%T.%3NZ)] CUSTOM SCORECARD TESTS DETECTED"
  CUSTOM_SERVICE_ACCOUNT="$(/usr/local/bin/yq r "${OPERATOR_DIR}/tests/scorecard/config.yaml" 'serviceaccount')"
  echo "[$(date --utc +%FT%T.%3NZ)] CUSTOM_SERVICE_ACCOUNT : ${CUSTOM_SERVICE_ACCOUNT}"
  # Set the scorecard service account to the default value used by the command (`default`)
  echo "[$(date --utc +%FT%T.%3NZ)] Set the SCORECARD_SERVICE_ACCOUNT to default"
  SCORECARD_SERVICE_ACCOUNT="default"
  echo "[$(date --utc +%FT%T.%3NZ)] contents of CUSTOM_SERVICE_ACCOUNT = $CUSTOM_SERVICE_ACCOUNT"
  echo "[$(date --utc +%FT%T.%3NZ)] contents of IS_CUSTOM_SERVICE_ACCOUNT_CREATED are $IS_CUSTOM_SERVICE_ACCOUNT_CREATED"
  if [[ ${CUSTOM_SERVICE_ACCOUNT} != "" && ${CUSTOM_SERVICE_ACCOUNT} != null && ${IS_CUSTOM_SERVICE_ACCOUNT_CREATED} == false ]]; then
    echo "[$(date --utc +%FT%T.%3NZ)] Creating service account ${CUSTOM_SERVICE_ACCOUNT} for usage wih the custom scorecard"
    oc create serviceaccount "${CUSTOM_SERVICE_ACCOUNT}" -n "${NAMESPACE}"
    oc create clusterrolebinding "default-sa-crb-${NAMESPACE}-${CUSTOM_SERVICE_ACCOUNT}" --clusterrole=cluster-admin --serviceaccount="${NAMESPACE}":"${CUSTOM_SERVICE_ACCOUNT}" 
    SCORECARD_SERVICE_ACCOUNT="${CUSTOM_SERVICE_ACCOUNT}"
  fi
  # Use the json output format for cvp custom scorecard tests
  CUSTOM_SCORECARD_OUTPUT_FORMAT="json"
  echo "[$(date --utc +%FT%T.%3NZ)] Running the operator-sdk scorecard test using the custom, bundle-provided configuration, json output and storing it in the artifacts directory"
  # Runs the custom scorecard tests using the user-provided configuration
  # The wait-time is set higher to allow for long/complex custom tests, should be kept under 1h to not exceed pipeline max time
  # If a custom service account is defined in the scorecard config, it will be set in the '--service-account' option
  run_scorecard custom_tests "${ARTIFACT_DIR}"/scorecard-output-custom."${CUSTOM_SCORECARD_OUTPUT_FORMAT}"
fi

echo "[$(date --utc +%FT%T.%3NZ)] Script Completed Execution Successfully !"

