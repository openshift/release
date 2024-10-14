#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if test -f "${SHARED_DIR}/api.login"; then
    eval "$(cat "${SHARED_DIR}/api.login")"
else
    echo "No ${SHARED_DIR}/api.login present. This is not an HCP or ROSA cluster. Continue using \$KUBECONFIG env path."
fi

git clone https://github.com/open-telemetry/opentelemetry-operator.git /tmp/otel-tests
cd /tmp/otel-tests 
git checkout -b downstream-release "${INTEROP_TESTS_COMMIT}"

# Add additional OpenTelemetry tests
git clone https://github.com/openshift/distributed-tracing-qe.git /tmp/distributed-tracing-qe \
&& mv /tmp/distributed-tracing-qe/tests/e2e-otel /tmp/otel-tests/tests/

#Enable user workload monitoring
oc apply -f tests/e2e-openshift/otlp-metrics-traces/01-workload-monitoring.yaml

#Set parameters for running the test cases on OpenShift and remove contrib collector images from tests.
unset NAMESPACE
find ./tests/e2e-otel ./tests/e2e-openshift -type f -exec sed -i '/image: ghcr.io\/open-telemetry\/opentelemetry-collector-releases\/opentelemetry-collector-contrib:/d' {} \;
# oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | xargs -I {} oc label nodes {} ingress-ready=true
OPAMP_BRIDGE_SERVER="quay.io/rhn_support_ikanse/opamp-bridge-server:v3.3"
find . -type f -exec sed -i "s|ghcr.io/open-telemetry/opentelemetry-operator/e2e-test-app-bridge-server:ve2e|${OPAMP_BRIDGE_SERVER}|g" {} \;
find ./tests/e2e-otel/journaldreceiver -type f -exec sed -i '/image: registry.redhat.io\/rhosdt\/opentelemetry-collector-rhel8@sha256:[a-f0-9]\{64\}/d' {} +

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
tests/e2e-targetallocator || any_errors=true

# Set the operator args required for tests execution.
OTEL_CSV_NAME=$(oc get csv -n openshift-opentelemetry-operator | grep "opentelemetry-operator" | awk '{print $1}')
oc -n openshift-opentelemetry-operator patch csv $OTEL_CSV_NAME --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args\",\"value\":[\"--metrics-addr=127.0.0.1:8080\", \"--enable-leader-election\", \"--zap-log-level=info\", \"--zap-time-encoding=rfc3339nano\", \"--operator-opamp-bridge-image=${OPERATOROPAMPBRIDGE_IMG}\", \"--enable-multi-instrumentation\", \"--openshift-create-dashboard=true\", \"--openshift-create-dashboard=true\", \"--feature-gates=+operator.observability.prometheus\", \"--enable-cr-metrics=true\"]}]"
sleep 10
oc wait --for condition=Available -n openshift-opentelemetry-operator deployment opentelemetry-operator-controller-manager

# Execute OpenTelemetry e2e tests
chainsaw test \
--report-name "junit_otel_multi_instrumentation" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
tests/e2e-multi-instrumentation || any_errors=true

# Set the operator args required for tests execution.
OTEL_CSV_NAME=$(oc get csv -n openshift-opentelemetry-operator | grep "opentelemetry-operator" | awk '{print $1}')
oc -n openshift-opentelemetry-operator patch csv $OTEL_CSV_NAME --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args\",\"value\":[\"--metrics-addr=127.0.0.1:8080\", \"--enable-leader-election\", \"--zap-log-level=info\", \"--zap-time-encoding=rfc3339nano\", \"--operator-opamp-bridge-image=${OPERATOROPAMPBRIDGE_IMG}\", \"--annotations-filter=.*filter.out\", \"--label=.*filter.out\", \"--openshift-create-dashboard=true\", \"--openshift-create-dashboard=true\", \"--feature-gates=+operator.observability.prometheus\", \"--enable-cr-metrics=true\"]}]"
sleep 10
oc wait --for condition=Available -n openshift-opentelemetry-operator deployment opentelemetry-operator-controller-manager

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