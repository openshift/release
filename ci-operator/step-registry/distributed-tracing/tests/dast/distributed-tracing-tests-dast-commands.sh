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

#Copy the distributed-tracing-qe repo files to a writable directory.
cd /tmp/
git clone -b nrop-test https://github.com/obochan-rh/distributed-tracing-qe.git /tmp/dastnrop/ # test from obochan fork
cp -R /tmp/dastnrop/ /tmp/distributed-tracing-tests && cd /tmp/distributed-tracing-tests

# Execute Distributed Tracing tests
chainsaw test \
--config ".chainsaw-rh-sdl.yaml" \
--report-name "junit_distributed_tracing_tests_dast" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
tests/e2e-rh-sdl
