#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Write a flat context file to SHARED_DIR so the qe-agent post-step can detect failures.
# SHARED_DIR only supports flat files (no subdirectories); subdirs are not propagated between steps.
function notify_qe_agent() {
    local has_failures=false
    grep -rqE '<(failure|error)[ >]' "${ARTIFACT_DIR}" 2>/dev/null && has_failures=true

    local i=0
    while IFS= read -r xml; do
        cp "${xml}" "${SHARED_DIR}/qe-agent-junit-${i}.xml" 2>/dev/null || true
        i=$((i + 1))
    done < <(find "${ARTIFACT_DIR}" -name "*.xml" 2>/dev/null)

    cat > "${SHARED_DIR}/qe-agent-context.json" <<EOF
{
  "step_script_ref": "distributed-tracing/tests/opentelemetry/downstream/distributed-tracing-tests-opentelemetry-downstream-commands.sh",
  "has_test_failures": ${has_failures},
  "env": {
    "MULTISTAGE_PARAM_OVERRIDE_OTEL_TESTS_BRANCH": "${MULTISTAGE_PARAM_OVERRIDE_OTEL_TESTS_BRANCH:-}"
  }
}
EOF
    echo "QE agent context and ${i} JUnit XML(s) written to SHARED_DIR (has_test_failures=${has_failures})"
}
trap notify_qe_agent EXIT

if [[ -z "${MULTISTAGE_PARAM_OVERRIDE_OTEL_TESTS_BRANCH:-}" ]]; then
  echo "ERROR: MULTISTAGE_PARAM_OVERRIDE_OTEL_TESTS_BRANCH is not set. Provide it via steps.env in the job config or via Gangway API pod_spec_options."
  exit 1
fi

git clone https://github.com/os-observability/opentelemetry-operator.git /tmp/otel-tests
cd /tmp/otel-tests
git checkout "${MULTISTAGE_PARAM_OVERRIDE_OTEL_TESTS_BRANCH}"

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
OTEL_CSV_NAME=$(oc get csv -n opentelemetry-operator-system | grep "opentelemetry-operator" | awk '{print $1}')
oc -n opentelemetry-operator-system patch csv $OTEL_CSV_NAME --type=json -p '[
  {"op":"add","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-","value":{"name":"ANNOTATIONS_FILTER","value":".*filter.out,config.*.gke.io.*"}},
  {"op":"add","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-","value":{"name":"LABELS_FILTER","value":".*filter.out"}}
]'
sleep 60
if oc -n opentelemetry-operator-system get deployment opentelemetry-operator-controller-manager -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' | grep -q "True"; then
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

# Execute TLS profile tests
chainsaw test \
--quiet \
--report-name "junit_otel_e2e_tls_profile" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
tests/e2e-openshift-tls-profile || any_errors=true

# Check if any errors occurred
if $any_errors; then
  echo "Tests failed, check the logs for more details."
  exit 1
else
  echo "All the tests passed."
fi
