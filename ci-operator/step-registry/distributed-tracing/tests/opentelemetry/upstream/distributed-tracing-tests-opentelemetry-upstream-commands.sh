#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Copy the opentelemetry-operator repo files to a writable directory by kuttl
cp -R /tmp/opentelemetry-operator /tmp/opentelemetry-tests && cd /tmp/opentelemetry-tests

# Add additional OpenTelemetry tests
git clone https://github.com/openshift/distributed-tracing-qe.git /tmp/distributed-tracing-qe \
&& mv /tmp/distributed-tracing-qe/tests/e2e-otel /tmp/opentelemetry-tests/tests/

#Enable user workload monitoring
oc apply -f tests/e2e-openshift/otlp-metrics-traces/01-workload-monitoring.yaml

#Set parameters for running the test cases on OpenShift
unset NAMESPACE
oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | xargs -I {} oc label nodes {} ingress-ready=true
#Set the Opamp bridge server image with the CI pipeline built image
find . -type f -exec sed -i "s|ghcr.io/open-telemetry/opentelemetry-operator/e2e-test-app-bridge-server:ve2e|${OPAMP_BRIDGE_SERVER}|g" {} \;

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

# Initialize a variable to keep track of errors
any_errors=false

# Set the operator args required for tests execution.
OTEL_CSV_NAME=$(oc get csv -n opentelemetry-operator | grep "opentelemetry-operator" | awk '{print $1}')
oc -n opentelemetry-operator patch csv $OTEL_CSV_NAME --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args\",\"value\":[\"--metrics-addr=127.0.0.1:8080\", \"--enable-leader-election\", \"--zap-log-level=info\", \"--zap-time-encoding=rfc3339nano\", \"--target-allocator-image=${TARGETALLOCATOR_IMG}\", \"--operator-opamp-bridge-image=${OPERATOROPAMPBRIDGE_IMG}\", \"--enable-go-instrumentation\", \"--enable-nginx-instrumentation=true\"]}]"
sleep 60
if oc -n opentelemetry-operator describe csv --selector=operators.coreos.com/opentelemetry-operator.opentelemetry-operator= | tail -n 1 | grep -qi "InstallSucceeded"; then
    echo "CSV updated successfully, continuing script execution..."
else
    echo "Operator CSV update failed, exiting with error."
    exit 1
fi

# Execute OpenTelemetry e2e tests
chainsaw test \
--report-name "junit_otel_e2e" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
tests/e2e \
tests/e2e-autoscale \
tests/e2e-openshift \
tests/e2e-prometheuscr \
tests/e2e-instrumentation \
tests/e2e-pdb \
tests/e2e-opampbridge \
tests/e2e-otel \
tests/e2e-targetallocator || any_errors=true

# Set the operator args required for tests execution.
OTEL_CSV_NAME=$(oc get csv -n opentelemetry-operator | grep "opentelemetry-operator" | awk '{print $1}')
oc -n opentelemetry-operator patch csv $OTEL_CSV_NAME --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args\",\"value\":[\"--metrics-addr=127.0.0.1:8080\", \"--enable-leader-election\", \"--zap-log-level=info\", \"--zap-time-encoding=rfc3339nano\", \"--target-allocator-image=${TARGETALLOCATOR_IMG}\", \"--operator-opamp-bridge-image=${OPERATOROPAMPBRIDGE_IMG}\", \"--enable-multi-instrumentation\"]}]"
sleep 60
if oc -n opentelemetry-operator describe csv --selector=operators.coreos.com/opentelemetry-operator.opentelemetry-operator= | tail -n 1 | grep -qi "InstallSucceeded"; then
    echo "CSV updated successfully, continuing script execution..."
else
    echo "Operator CSV update failed, exiting with error."
    exit 1
fi

# Execute OpenTelemetry e2e tests
chainsaw test \
--report-name "junit_otel_multi_instrumentation" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
tests/e2e-multi-instrumentation || any_errors=true

# Set the operator args required for tests execution.
OTEL_CSV_NAME=$(oc get csv -n opentelemetry-operator | grep "opentelemetry-operator" | awk '{print $1}')
oc -n opentelemetry-operator patch csv $OTEL_CSV_NAME --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args\",\"value\":[\"--metrics-addr=127.0.0.1:8080\", \"--enable-leader-election\", \"--zap-log-level=info\", \"--zap-time-encoding=rfc3339nano\", \"--target-allocator-image=${TARGETALLOCATOR_IMG}\", \"--operator-opamp-bridge-image=${OPERATOROPAMPBRIDGE_IMG}\", \"--annotations-filter=.*filter.out\", \"--annotations-filter=config.*.gke.io.*\", \"--label=.*filter.out\"]}]"
sleep 60
if oc -n opentelemetry-operator describe csv --selector=operators.coreos.com/opentelemetry-operator.opentelemetry-operator= | tail -n 1 | grep -qi "InstallSucceeded"; then
    echo "CSV updated successfully, continuing script execution..."
else
    echo "Operator CSV update failed, exiting with error."
    exit 1
fi

# Execute OpenTelemetry e2e tests
chainsaw test \
--report-name "junit_otel_metadata_filters" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
tests/e2e-metadata-filters || any_errors=true

# Check if any errors occurred
if $any_errors; then
  echo "Tests failed, check the logs for more details."
  exit 1
else
  echo "All the tests passed."
fi
