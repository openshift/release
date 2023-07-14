#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Add manifest directory for kuttl
mkdir /tmp/kuttl-manifests && cp /tmp/tempo-operator/minio.yaml /tmp/kuttl-manifests

#Copy the tempo-operator repo files to a writable directory by kuttl
cp -R /tmp/tempo-operator /tmp/tempo-tests && cd /tmp/tempo-tests

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
  echo "These test cases are not valid to be skipped $INVALID_TESTS"
fi

if [[ -n "$SKIP_TESTS_TO_REMOVE" ]]; then
  rm -rf $SKIP_TESTS_TO_REMOVE
fi

# Execute Tempo e2e tests
KUBECONFIG=$KUBECONFIG kuttl test \
  --report=xml \
  --artifacts-dir="$ARTIFACT_DIR" \
  --parallel="$PARALLEL_TESTS" \
  --report-name="$REPORT_NAME" \
  --start-kind=false \
  --timeout="$TIMEOUT" \
  --manifest-dir=$MANIFEST_DIR \
  tests/e2e \
  tests/e2e-openshift
