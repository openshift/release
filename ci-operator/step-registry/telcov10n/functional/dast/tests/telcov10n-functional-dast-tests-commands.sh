!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# set default values
WORKSPACE=${SHARED_DIR}
export KUBECONFIG=${WORKSPACE}/kubeconfig

# Unset environment variables which conflict with kubectl
unset NAMESPACE

#Copy the distributed-tracing-qe repo files to a writable directory.
cp -R /tmp/telco-dast-qe /tmp/telco-dast-qe && cd /tmp/telco-dast-qe

# Execute test
chainsaw test \
--config ".chainsaw" \
--report-name "junit_telco_tests_dast" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
tests/dast
