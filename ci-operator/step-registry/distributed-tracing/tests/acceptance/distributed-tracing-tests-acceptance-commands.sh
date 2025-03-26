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
cp -R /tmp/distributed-tracing-qe /tmp/distributed-tracing-tests && cd /tmp/distributed-tracing-tests

#Enable user workload monitoring
oc apply -f tests/e2e-acceptance/otlp-metrics-traces/01-workload-monitoring.yaml
#Tag OCP worker nodes required for targetallocator features test
oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | xargs -I {} oc label nodes {} ingress-ready=true

# Execute Distributed Tracing tests
chainsaw test \
--report-name "junit_distributed_tracing_tests_acceptance" \
--report-path "$ARTIFACT_DIR" \
--report-format "XML" \
--test-dir \
tests/e2e-acceptance \
tests/e2e-otel
