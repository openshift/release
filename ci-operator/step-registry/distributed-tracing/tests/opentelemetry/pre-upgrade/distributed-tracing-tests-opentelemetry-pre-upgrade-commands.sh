#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

git clone https://github.com/IshwarKanse/opentelemetry-operator.git /tmp/otel-tests
cd /tmp/otel-tests 
git checkout rhosdt-3-5

#Enable user workload monitoring
oc apply -f tests/e2e-openshift/otlp-metrics-traces/01-workload-monitoring.yaml

#Set parameters for running the test cases on OpenShift and remove contrib collector images from tests.
unset NAMESPACE

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

# Set the operator args required for tests execution.
OTEL_CSV_NAME=$(oc get csv -n opentelemetry-operator | grep "opentelemetry-operator" | awk '{print $1}')
oc -n opentelemetry-operator patch csv $OTEL_CSV_NAME --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args\",\"value\":[\"--metrics-addr=127.0.0.1:8080\", \"--enable-leader-election\", \"--zap-log-level=info\", \"--zap-time-encoding=rfc3339nano\", \"--target-allocator-image=${TARGETALLOCATOR_IMG}\", \"--operator-opamp-bridge-image=${OPERATOROPAMPBRIDGE_IMG}\", \"--enable-go-instrumentation\", \"--openshift-create-dashboard=true\", \"--feature-gates=+operator.observability.prometheus\", \"--enable-nginx-instrumentation=true\"]}]"
sleep 60
if oc -n opentelemetry-operator describe csv --selector=operators.coreos.com/opentelemetry-operator.opentelemetry-operator= | tail -n 1 | grep -qi "InstallSucceeded"; then
    echo "CSV updated successfully, continuing script execution..."
else
    echo "Operator CSV update failed, exiting with error."
    exit 1
fi

# Execute OpenTelemetry e2e tests
chainsaw test \
--report-name "junit_otel_pre_upgrade_e2e" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
tests/e2e \
tests/e2e-openshift