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

# Unset environment variable which conflicts with Chainsaw
unset NAMESPACE

# Initialize a variable to keep track of errors
any_errors=false

# Execute Tempo e2e tests
chainsaw test \
--config .chainsaw-openshift.yaml \
--report-name "junit_tempo_e2e" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
tests/e2e \
tests/e2e-openshift \
tests/e2e-openshift-serverless \
tests/e2e-openshift-ossm || any_errors=true

# Get the platform type
dt_platform_type=$(oc get infrastructures cluster -o=jsonpath='{.status.platformStatus.type}')
echo "Platform is $dt_platform_type"

# Check if the cluster is STS or WIF cluster
dt_wif_or_sts=$(oc get authentication cluster -o=jsonpath='{.spec.serviceAccountIssuer}')
echo "$dt_wif_or_sts"

if [[ "$dt_platform_type" == "AWS" && -n "$dt_wif_or_sts" ]]; then
    chainsaw test \
        --config .chainsaw-openshift.yaml \
        --report-name "junit_tempo_aws-sts" \
        --report-path "$ARTIFACT_DIR" \
        --selector type=aws-sts \
        --report-format "XML" \
        --test-dir tests/e2e-openshift-object-stores || any_errors=true
else
    echo "Cluster is not AWS STS cluster, skipping the AWS STS tests"
fi

# Check if any errors occurred
if $any_errors; then
  echo "Tests failed, check the logs for more details."
  exit 1
else
  echo "All the tests passed."
fi
