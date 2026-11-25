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
  "step_script_ref": "distributed-tracing/tests/tempo/downstream/distributed-tracing-tests-tempo-downstream-commands.sh",
  "has_test_failures": ${has_failures},
  "env": {
    "MULTISTAGE_PARAM_OVERRIDE_TEMPO_TESTS_BRANCH": "${MULTISTAGE_PARAM_OVERRIDE_TEMPO_TESTS_BRANCH:-}"
  }
}
EOF
    echo "QE agent context and ${i} JUnit XML(s) written to SHARED_DIR (has_test_failures=${has_failures})"
}
trap notify_qe_agent EXIT

# Used for downstream testing.
# Set the Go path and Go cache environment variables
export GOPATH=/tmp/go
export GOBIN=/tmp/go/bin
export GOCACHE=/tmp/.cache/go-build

# Create the /tmp/go/bin and build cache directories, and grant read and write permissions to all users
mkdir -p /tmp/go/bin $GOCACHE \
  && chmod -R 777 /tmp/go/bin $GOPATH $GOCACHE

if [[ -z "${MULTISTAGE_PARAM_OVERRIDE_TEMPO_TESTS_BRANCH:-}" ]]; then
  echo "ERROR: MULTISTAGE_PARAM_OVERRIDE_TEMPO_TESTS_BRANCH is not set. Provide it via steps.env in the job config or via Gangway API pod_spec_options."
  exit 1
fi

git clone https://github.com/os-observability/tempo-operator.git /tmp/tempo-tests
cd /tmp/tempo-tests
git checkout "${MULTISTAGE_PARAM_OVERRIDE_TEMPO_TESTS_BRANCH}"
make build

#Enable user workload monitoring.
oc apply -f tests/e2e-openshift/monitoring/01-workload-monitoring.yaml

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

# Unset environment variable which conflicts with Chainsaw
unset NAMESPACE

# Initialize a variable to keep track of errors
any_errors=false

# Execute Tempo e2e tests
chainsaw test \
--quiet \
--config .chainsaw-openshift.yaml \
--report-name "junit_tempo_e2e" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
tests/e2e \
tests/e2e-openshift \
tests/e2e-openshift-serverless \
tests/e2e-openshift-ossm \
tests/e2e-openshift-object-stores \
tests/e2e-long-running \
tests/e2e-openshift-tshirt-sizes \
tests/operator-metrics || any_errors=true

# Execute TLS profile tests last: they patch the cluster-wide APIServer resource,
# triggering node-level TLS reconciliation that would disrupt concurrently running tests.
chainsaw test \
--quiet \
--config .chainsaw-openshift.yaml \
--report-name "junit_tempo_e2e_tls_profile" \
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
