#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

git clone https://github.com/IshwarKanse/opentelemetry-operator.git /tmp/otel-tests
cd /tmp/otel-tests 
git checkout rhosdt-3.7

#Enable user workload monitoring
oc apply -f tests/e2e-openshift/otlp-metrics-traces/01-workload-monitoring.yaml

# Install Prometheus ScrapeConfig CRD
kubectl create -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_scrapeconfigs.yaml

#Set parameters for running the test cases on OpenShift and remove contrib collector images from tests.
unset NAMESPACE

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

# Determine OpenShift version and set sidecar selector (unified parsing)
oc_version_minor=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null | cut -d . -f 2 || true)
selector="sidecar=legacy"
if [[ -n "$oc_version_minor" ]] && [[ "$oc_version_minor" -ge 16 ]]; then
  selector="sidecar=native"
fi

# Execute OpenTelemetry e2e tests
chainsaw test \
--report-name "junit_otel_e2e" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
tests/e2e \
tests/e2e-autoscale \
tests/e2e-crd-validations \
tests/e2e-openshift \
tests/e2e-instrumentation \
tests/e2e-pdb \
tests/e2e-opampbridge \
tests/e2e-otel \
tests/e2e-multi-instrumentation \
tests/e2e-targetallocator-cr \
tests/e2e-targetallocator || any_errors=true

# Execute sidecar-related tests with version-dependent selector
chainsaw test \
--report-name "junit_otel_e2e_sidecar_prometheuscr" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--selector "$selector" \
--test-dir \
tests/e2e-prometheuscr \
tests/e2e-sidecar || any_errors=true

# Set the operator args required for tests execution.
OTEL_CSV_NAME=$(oc get csv -n openshift-opentelemetry-operator | grep "opentelemetry-operator" | awk '{print $1}')
oc -n openshift-opentelemetry-operator patch csv $OTEL_CSV_NAME --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args\",\"value\":[\"--metrics-addr=127.0.0.1:8080\", \"--enable-leader-election\", \"--zap-log-level=info\", \"--zap-time-encoding=rfc3339nano\", \"--enable-go-instrumentation\", \"--openshift-create-dashboard=true\", \"--enable-nginx-instrumentation=true\", \"--enable-cr-metrics=true\", \"--create-sm-operator-metrics=true\", \"--annotations-filter=.*filter.out\", \"--annotations-filter=config.*.gke.io.*\", \"--labels-filter=.*filter.out\", \"--feature-gates=operator.networkpolicy,operand.networkpolicy\"]}]"
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
