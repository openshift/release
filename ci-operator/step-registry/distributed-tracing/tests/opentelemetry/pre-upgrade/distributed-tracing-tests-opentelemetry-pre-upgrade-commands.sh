#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Add manifest directory for kuttl
mkdir /tmp/kuttl-manifests

#Copy the opentelemetry-operator repo files to a writable directory by kuttl
cp -R /tmp/opentelemetry-operator /tmp/opentelemetry-tests && cd /tmp/opentelemetry-tests

#Set parameters for running the test cases on OpenShift
TARGETALLOCATOR_IMG=$TARGETALLOCATOR_IMG SED_BIN="$(which sed)" ./hack/modify-test-images.sh
sed -i 's/- -duration=1m/- -duration=6m/' tests/e2e-autoscale/autoscale/03-install.yaml

#Skip tests
unset SKIP_TESTS
export SKIP_TESTS="tests/e2e-autoscale/autoscale tests/e2e/instrumentation-sdk tests/e2e/instrumentation-go tests/e2e/instrumentation-apache-multicontainer tests/e2e/instrumentation-apache-httpd tests/e2e/route tests/e2e/targetallocator-features tests/e2e/prometheus-config-validation tests/e2e/smoke-targetallocator tests/e2e-openshift/otlp-metrics-traces tests/e2e/instrumentation-nodejs tests/e2e/instrumentation-python tests/e2e/instrumentation-java tests/e2e/instrumentation-dotnet tests/e2e/smoke-init-containers"

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
  echo "These test cases are not valid to be skipped $INVALID_TESTS"
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
