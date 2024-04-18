#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Unset environment variables which conflict with kuttl
unset NAMESPACE

# setup proxy
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

#Select the test suite based on the DT_TEST_TYPE
if [[ "${DT_TEST_TYPE}" == "DAST" ]]; then

  #Copy the distributed-tracing-qe repo files to a writable directory.
  cp -R /tmp/distributed-tracing-qe /tmp/distributed-tracing-tests && cd /tmp/distributed-tracing-tests

  # Execute Distributed Tracing tests
  chainsaw test \
  --config ".chainsaw-rh-sdl.yaml" \
  --report-name "$REPORT_NAME" \
  --report-path "$ARTIFACT_DIR" \
  --report-format "XML" \
  --test-dir \
  tests/e2e-rh-sdl

else

  #Copy the distributed-tracing-qe repo files to a writable directory.
  cp -R /tmp/distributed-tracing-qe /tmp/distributed-tracing-tests && cd /tmp/distributed-tracing-tests

  # Execute Distributed Tracing tests
  chainsaw test \
  --report-name "$REPORT_NAME" \
  --report-path "$ARTIFACT_DIR" \
  --report-format "XML" \
  --test-dir \
  tests/e2e-acceptance

fi
