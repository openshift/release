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

# Install Prometheus ScrapeConfig CRD
kubectl create -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_scrapeconfigs.yaml

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

# Set the operator environment variables required for tests execution.
OTEL_CSV_NAME=$(oc get csv -n opentelemetry-operator | grep "opentelemetry-operator" | awk '{print $1}')
oc -n opentelemetry-operator patch csv $OTEL_CSV_NAME --type=json -p '[
  {"op":"add","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-","value":{"name":"RELATED_IMAGE_TARGET_ALLOCATOR","value":"'"${TARGETALLOCATOR_IMG}"'"}},
  {"op":"add","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-","value":{"name":"RELATED_IMAGE_OPERATOR_OPAMP_BRIDGE","value":"'"${OPERATOROPAMPBRIDGE_IMG}"'"}}
]'
sleep 60
if oc -n opentelemetry-operator get deployment opentelemetry-operator-controller-manager -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' | grep -q "True"; then
    echo "Operator deployment updated successfully, continuing script execution..."
else
    echo "Operator deployment update failed, exiting with error."
    exit 1
fi

# Determine OpenShift version and set sidecar selector (unified parsing)
oc_version_minor=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null | cut -d . -f 2 || true)
selector="sidecar=legacy"
if [[ -n "$oc_version_minor" ]] && [[ "$oc_version_minor" -ge 16 ]]; then
  selector="sidecar=native"
fi

# Execute OpenTelemetry e2e tests
chainsaw test \
--quiet \
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
--quiet \
--report-name "junit_otel_e2e_sidecar_prometheuscr" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--selector "$selector" \
--test-dir \
tests/e2e-prometheuscr \
tests/e2e-sidecar || any_errors=true

# Set the operator environment variables for metadata filters tests.
OTEL_CSV_NAME=$(oc get csv -n opentelemetry-operator | grep "opentelemetry-operator" | awk '{print $1}')
oc -n opentelemetry-operator patch csv $OTEL_CSV_NAME --type=json -p '[
  {"op":"add","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-","value":{"name":"ANNOTATIONS_FILTER","value":".*filter.out,config.*.gke.io.*"}},
  {"op":"add","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-","value":{"name":"LABELS_FILTER","value":".*filter.out"}}
]'
sleep 60
if oc -n opentelemetry-operator get deployment opentelemetry-operator-controller-manager -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' | grep -q "True"; then
    echo "Operator deployment updated successfully for metadata filters, continuing script execution..."
else
    echo "Operator deployment update for metadata filters failed, exiting with error."
    exit 1
fi

# Execute OpenTelemetry e2e tests
chainsaw test \
--quiet \
--report-name "junit_otel_metadata_filters" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
tests/e2e-metadata-filters || any_errors=true

# Set the operator environment variables with instrumentation images for e2e-instrumentation tests.
OTEL_CSV_NAME=$(oc get csv -n opentelemetry-operator | grep "opentelemetry-operator" | awk '{print $1}')
oc -n opentelemetry-operator patch csv $OTEL_CSV_NAME --type=json -p '[
  {"op":"add","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-","value":{"name":"RELATED_IMAGE_AUTO_INSTRUMENTATION_JAVA","value":"'"${INSTRUMENTATION_JAVA_IMG}"'"}},
  {"op":"add","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-","value":{"name":"RELATED_IMAGE_AUTO_INSTRUMENTATION_NODEJS","value":"'"${INSTRUMENTATION_NODEJS_IMG}"'"}},
  {"op":"add","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-","value":{"name":"RELATED_IMAGE_AUTO_INSTRUMENTATION_PYTHON","value":"'"${INSTRUMENTATION_PYTHON_IMG}"'"}},
  {"op":"add","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-","value":{"name":"RELATED_IMAGE_AUTO_INSTRUMENTATION_DOTNET","value":"'"${INSTRUMENTATION_DOTNET_IMG}"'"}},
  {"op":"add","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-","value":{"name":"RELATED_IMAGE_AUTO_INSTRUMENTATION_APACHE_HTTPD","value":"'"${INSTRUMENTATION_APACHE_HTTPD_IMG}"'"}}
]'
sleep 60
if oc -n opentelemetry-operator get deployment opentelemetry-operator-controller-manager -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' | grep -q "True"; then
    echo "Operator deployment updated successfully with instrumentation images, continuing script execution..."
else
    echo "Operator deployment update with instrumentation images failed, exiting with error."
    exit 1
fi

# Execute OpenTelemetry e2e-instrumentation tests with pipeline instrumentation images
chainsaw test \
--quiet \
--report-name "junit_otel_e2e_instrumentation_pipeline_images" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
tests/e2e-instrumentation \
tests/e2e-multi-instrumentation || any_errors=true

# Check if any errors occurred
if $any_errors; then
  echo "Tests failed, check the logs for more details."
  exit 1
else
  echo "All the tests passed."
fi
