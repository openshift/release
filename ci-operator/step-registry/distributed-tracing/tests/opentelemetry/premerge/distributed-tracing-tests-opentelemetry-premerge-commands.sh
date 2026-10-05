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

    cat > "${SHARED_DIR}/qe-agent-context.json" <<CONTEXT
{
  "step_script_ref": "distributed-tracing/tests/opentelemetry/premerge/distributed-tracing-tests-opentelemetry-premerge-commands.sh",
  "has_test_failures": ${has_failures},
  "env": {
    "OTEL_COLLECTOR_IMAGE": "${OTEL_COLLECTOR_IMAGE:-}",
    "TARGETALLOCATOR_IMG": "${TARGETALLOCATOR_IMG:-}"
  }
}
CONTEXT
    echo "QE agent context and ${i} JUnit XML(s) written to SHARED_DIR (has_test_failures=${has_failures})"
}
trap notify_qe_agent EXIT

if [[ -z "${OTEL_COLLECTOR_IMAGE:-}" || -z "${TARGETALLOCATOR_IMG:-}" ]]; then
  echo "ERROR: OTEL_COLLECTOR_IMAGE and TARGETALLOCATOR_IMG must be set. They are filled from the opentelemetry-collector and opentelemetry-target-allocator-art pipeline images."
  exit 1
fi
echo "Collector image under test: ${OTEL_COLLECTOR_IMAGE}"
echo "Target allocator image under test: ${TARGETALLOCATOR_IMG}"

# Copy the operator repository (the pull request source baked into the obs-tests-runner image) to a writable directory.
cp -R /tmp/opentelemetry-operator /tmp/otel-tests
cd /tmp/otel-tests

# Enable user workload monitoring
oc apply -f tests/e2e-openshift/otlp-metrics-traces/01-workload-monitoring.yaml

# Install Prometheus ScrapeConfig CRD
kubectl create -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_scrapeconfigs.yaml

# Set parameters for running the test cases on OpenShift.
unset NAMESPACE
oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | xargs -I {} oc label nodes {} ingress-ready=true

# Remove test cases to be skipped from the test run
IFS=' ' read -ra SKIP_TEST_ARRAY <<< "${SKIP_TESTS:-}"
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
  # shellcheck disable=SC2086 # the glob patterns in SKIP_TESTS must be expanded
  rm -rf $SKIP_TESTS_TO_REMOVE
fi

# Initialize a variable to keep track of errors
any_errors=false

OPERATOR_NAMESPACE="opentelemetry-operator-system"
OPERATOR_DEPLOYMENT="opentelemetry-operator-controller-manager"

# Wait until the operator deployment reports Available after a CSV change.
function wait_for_operator() {
  local description="$1"
  sleep 60
  if oc -n "${OPERATOR_NAMESPACE}" get deployment "${OPERATOR_DEPLOYMENT}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' | grep -q "True"; then
    echo "Operator deployment updated successfully ${description}, continuing script execution..."
  else
    echo "Operator deployment update ${description} failed, exiting with error."
    exit 1
  fi
}

function csv_name() {
  oc get csv -n "${OPERATOR_NAMESPACE}" -o name | grep -m1 "opentelemetry-operator" | cut -d/ -f2
}

# Point the operator at the collector and target allocator images built in this CI run.
oc -n "${OPERATOR_NAMESPACE}" patch csv "$(csv_name)" --type=json -p '[
  {"op":"add","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-","value":{"name":"RELATED_IMAGE_COLLECTOR","value":"'"${OTEL_COLLECTOR_IMAGE}"'"}},
  {"op":"add","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-","value":{"name":"RELATED_IMAGE_TARGET_ALLOCATOR","value":"'"${TARGETALLOCATOR_IMG}"'"}}
]'
wait_for_operator "with the collector and target allocator images"

# Determine OpenShift version and set sidecar selector (unified parsing)
oc_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
oc_version_major=$(echo "$oc_version" | cut -d . -f 1)
oc_version_minor=$(echo "$oc_version" | cut -d . -f 2)
selector="sidecar=legacy"
if [[ -n "$oc_version_major" ]] && { [[ "$oc_version_major" -ge 5 ]] || { [[ "$oc_version_major" -eq 4 ]] && [[ "$oc_version_minor" -ge 16 ]]; }; }; then
  selector="sidecar=native"
fi

# Execute OpenTelemetry e2e tests
# shellcheck disable=SC2086 # TEST_DIRS is a space separated list
chainsaw test \
--quiet \
--report-name "junit_otel_e2e" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
${TEST_DIRS} || any_errors=true

# Execute sidecar-related tests with version-dependent selector
if [[ -n "${SIDECAR_TEST_DIRS:-}" ]]; then
  # shellcheck disable=SC2086 # SIDECAR_TEST_DIRS is a space separated list
  chainsaw test \
  --quiet \
  --report-name "junit_otel_e2e_sidecar_prometheuscr" \
  --report-path "$ARTIFACT_DIR" \
  --report-format "XML" \
  --selector "$selector" \
  --test-dir \
  ${SIDECAR_TEST_DIRS} || any_errors=true
fi

if [[ "${RUN_METADATA_FILTER_TESTS:-false}" == "true" ]]; then
  # Set the operator environment variables for metadata filters tests.
  oc -n "${OPERATOR_NAMESPACE}" patch csv "$(csv_name)" --type=json -p '[
    {"op":"add","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-","value":{"name":"ANNOTATIONS_FILTER","value":".*filter.out,config.*.gke.io.*"}},
    {"op":"add","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-","value":{"name":"LABELS_FILTER","value":".*filter.out"}}
  ]'
  wait_for_operator "for metadata filters"

  chainsaw test \
  --quiet \
  --report-name "junit_otel_metadata_filters" \
  --report-path "$ARTIFACT_DIR" \
  --report-format "XML" \
  --test-dir \
  tests/e2e-metadata-filters || any_errors=true
fi

if [[ "${RUN_TLS_PROFILE_TESTS:-false}" == "true" ]]; then
  # Execute TLS profile tests
  chainsaw test \
  --quiet \
  --report-name "junit_otel_e2e_tls_profile" \
  --report-path "$ARTIFACT_DIR" \
  --report-format "XML" \
  --test-dir \
  tests/e2e-openshift-tls-profile || any_errors=true
fi

# Check if any errors occurred
if $any_errors; then
  echo "Tests failed, check the logs for more details."
  exit 1
else
  echo "All the tests passed."
fi
