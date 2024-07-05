#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Used for downstream testing.
# Set the Go path and Go cache environment variables
export GOPATH=/tmp/go
export GOBIN=/tmp/go/bin
export GOCACHE=/tmp/.cache/go-build

# Create the /tmp/go/bin and build cache directories, and grant read and write permissions to all users
mkdir -p /tmp/go/bin $GOCACHE \
  && chmod -R 777 /tmp/go/bin $GOPATH $GOCACHE

git clone https://github.com/grafana/tempo-operator.git /tmp/tempo-tests
cd /tmp/tempo-tests
git checkout -b downstream-release "${INTEROP_TESTS_COMMIT}"
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

# Unset environment variables which conflict with kuttl
unset NAMESPACE

# Execute Tempo e2e tests
chainsaw test \
--config .chainsaw-openshift.yaml \
--report-name "junit_tempo_e2e" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
tests/e2e \
tests/e2e-openshift \
tests/e2e-openshift-ossm