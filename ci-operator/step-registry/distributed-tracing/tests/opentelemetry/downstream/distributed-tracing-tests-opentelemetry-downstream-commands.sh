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
#find ./tests/e2e-otel ./tests/e2e-openshift -type f -exec sed -i '/image: ghcr.io\/open-telemetry\/opentelemetry-collector-releases\/opentelemetry-collector-contrib:/d' {} \;
oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | xargs -I {} oc label nodes {} ingress-ready=true
#OPAMP_BRIDGE_SERVER="quay.io/rhn_support_ikanse/opamp-bridge-server:v3.3"
#find . -type f -exec sed -i "s|ghcr.io/open-telemetry/opentelemetry-operator/e2e-test-app-bridge-server:ve2e|${OPAMP_BRIDGE_SERVER}|g" {} \;
#find ./tests/e2e-otel/journaldreceiver -type f -exec sed -i '/image: registry.redhat.io\/rhosdt\/opentelemetry-collector-rhel8@sha256:[a-f0-9]\{64\}/d' {} +

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
tests/e2e-multi-instrumentation \
tests/e2e-targetallocator || any_errors=true

# Set the operator args required for tests execution.
OTEL_CSV_NAME=$(oc get csv -n openshift-opentelemetry-operator | grep "opentelemetry-operator" | awk '{print $1}')
oc -n openshift-opentelemetry-operator patch csv $OTEL_CSV_NAME --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args\",\"value\":[\"--metrics-addr=127.0.0.1:8080\", \"--enable-leader-election\", \"--zap-log-level=info\", \"--zap-time-encoding=rfc3339nano\", \"--annotations-filter=.*filter.out\", \"--annotations-filter=config.*.gke.io.*\", \"--labels-filter=.*filter.out\"]}]"
sleep 60
if oc -n openshift-opentelemetry-operator describe csv --selector=operators.coreos.com/opentelemetry-product.openshift-opentelemetry-operator= | tail -n 1 | grep -qi "InstallSucceeded"; then
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
