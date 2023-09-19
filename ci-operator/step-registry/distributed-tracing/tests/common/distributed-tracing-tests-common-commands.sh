#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Unset environment variables which conflict with kuttl
unset NAMESPACE

#Add manifest directory for kuttl
mkdir /tmp/kuttl-manifests

#Copy the distributed-tracing-qe repo files to a writable directory by kuttl
cp -R /tmp/distributed-tracing-qe /tmp/distributed-tracing-tests && cd /tmp/distributed-tracing-tests

# Execute Distributed Tracing tests
KUBECONFIG=$KUBECONFIG kuttl test \
  --report=xml \
  --artifacts-dir="$ARTIFACT_DIR" \
  --parallel="$PARALLEL_TESTS" \
  --report-name="$REPORT_NAME" \
  --start-kind=false \
  --timeout="$TIMEOUT" \
  --manifest-dir=$MANIFEST_DIR \
  tests/e2e-rh-sdl
