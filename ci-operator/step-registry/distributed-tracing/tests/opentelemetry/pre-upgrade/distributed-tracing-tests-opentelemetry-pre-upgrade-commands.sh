#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Add manifest directory for kuttl
mkdir /tmp/kuttl-manifests

# If the DOWNSTREAM_TESTS_COMMIT variable is set, clone the repository with the specified commit
if [[ -n "${DOWNSTREAM_TESTS_COMMIT}" ]]; then
  git clone https://github.com/open-telemetry/opentelemetry-operator.git /tmp/otel-tests
  cd /tmp/otel-tests
  git checkout -b downstream-release "${DOWNSTREAM_TESTS_COMMIT}"
  
  #Set parameters for running the test cases on OpenShift
  unset NAMESPACE
  TARGETALLOCATOR_IMG=$TARGETALLOCATOR_IMG SED_BIN="$(which sed)" ./hack/modify-test-images.sh
  sed -i 's/- -duration=1m/- -duration=6m/' tests/e2e-autoscale/autoscale/03-install.yaml

  # Remove test cases to be skipped from the test run
  IFS=' ' read -ra SKIP_TEST_ARRAY <<< "$PRE_UPG_SKIP_TESTS"
  SKIP_TESTS_TO_REMOVE=""
  INVALID_TESTS=""
  for test in "${SKIP_TEST_ARRAY[@]}"; do
    if [[ "$test" == tests/* ]]; then
      SKIP_TESTS_TO_REMOVE+=" $test"
    else
      INVALID_TESTS+=" $test"
    fi
  done

  if [[ -n "$INVALID_TESTS" ]]; then
    echo "These test cases are not valid to be skipped: $INVALID_TESTS"
  fi

  if [[ -n "$SKIP_TESTS_TO_REMOVE" ]]; then
    rm -rf $SKIP_TESTS_TO_REMOVE
  fi

  # Execute OpenTelemetry e2e tests
  KUBECONFIG=$KUBECONFIG kuttl test \
    --report=xml \
    --artifacts-dir="$ARTIFACT_DIR" \
    --parallel="$PARALLEL_TESTS" \
    --report-name="$REPORT_NAME" \
    --start-kind=false \
    --timeout="$TIMEOUT" \
    --manifest-dir=$MANIFEST_DIR \
    tests/e2e \
    tests/e2e-autoscale \
    tests/e2e-openshift 

else

  #Copy the opentelemetry-operator repo files to a writable directory by kuttl
  cp -R /tmp/opentelemetry-operator /tmp/opentelemetry-tests && cd /tmp/opentelemetry-tests

  #Set parameters for running the test cases on OpenShift
  unset NAMESPACE
  TARGETALLOCATOR_IMG=$TARGETALLOCATOR_IMG SED_BIN="$(which sed)" ./hack/modify-test-images.sh
  sed -i 's/- -duration=1m/- -duration=6m/' tests/e2e-autoscale/autoscale/03-install.yaml

  # Remove test cases to be skipped from the test run
  IFS=' ' read -ra SKIP_TEST_ARRAY <<< "$SKIP_TESTS"
  SKIP_TESTS_TO_REMOVE=""
  INVALID_TESTS=""
  for test in "${SKIP_TEST_ARRAY[@]}"; do
    if [[ "$test" == tests/* ]]; then
      SKIP_TESTS_TO_REMOVE+=" $test"
    else
      INVALID_TESTS+=" $test"
    fi
  done

  if [[ -n "$INVALID_TESTS" ]]; then
    echo "These test cases are not valid to be skipped: $INVALID_TESTS"
  fi

  if [[ -n "$SKIP_TESTS_TO_REMOVE" ]]; then
    rm -rf $SKIP_TESTS_TO_REMOVE
  fi

  # Execute OpenTelemetry e2e tests
  KUBECONFIG=$KUBECONFIG kuttl test \
    --report=xml \
    --artifacts-dir="$ARTIFACT_DIR" \
    --parallel="$PARALLEL_TESTS" \
    --report-name="$REPORT_NAME" \
    --start-kind=false \
    --timeout="$TIMEOUT" \
    --manifest-dir=$MANIFEST_DIR \
    tests/e2e \
    tests/e2e-autoscale \
    tests/e2e-openshift \
    tests/e2e-instrumentation
fi
