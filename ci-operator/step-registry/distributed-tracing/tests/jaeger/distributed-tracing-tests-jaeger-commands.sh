#!/bin/bash

set -o errexit
set -o pipefail

# Unset environment variables which conflict with kuttl
unset NAMESPACE

# Copy the jaeger-operator repo files to a writable directory by kuttl
cp -R /tmp/jaeger-operator /tmp/jaeger-tests && cd /tmp/jaeger-tests

# Replace with patched files for running Jaeger tests on Prow CI
curl -o tests/e2e/Makefile -L https://raw.githubusercontent.com/IshwarKanse/test-files/main/jaeger-operator/tests/e2e/Makefile
curl -o hack/run-e2e-test-suite.sh -L https://raw.githubusercontent.com/IshwarKanse/test-files/main/jaeger-operator/hack/run-e2e-test-suite.sh
curl -o hack/install/install-kuttl.sh -L https://raw.githubusercontent.com/IshwarKanse/test-files/main/jaeger-operator/hack/install/install-kuttl.sh
curl -o tests/e2e/elasticsearch/render.sh https://raw.githubusercontent.com/IshwarKanse/test-files/main/jaeger-operator/tests/e2e/elasticsearch/render.sh
curl -o tests/e2e/miscellaneous/render.sh https://raw.githubusercontent.com/IshwarKanse/test-files/main/jaeger-operator/tests/e2e/miscellaneous/render.sh
curl -o tests/e2e/streaming/render.sh https://raw.githubusercontent.com/IshwarKanse/test-files/main/jaeger-operator/tests/e2e/streaming/render.sh
curl -o tests/e2e/examples/render.sh https://raw.githubusercontent.com/IshwarKanse/test-files/main/jaeger-operator/tests/e2e/examples/render.sh
./hack/install/install-kuttl.sh

rm -rf tests/e2e/elasticsearch/es-rollover-upstream/
rm -rf tests/e2e/elasticsearch/es-index-cleaner-upstream/
rm -rf tests/e2e/miscellaneous/collector-autoscale/
rm -rf tests/e2e/streaming/streaming-with-autoprovisioning-autoscale/
rm -rf tests/e2e/examples/examples-openshift-agent-as-daemonset/


# Run the e2e tests
make run-e2e-tests ASSERT_IMG=$ASSERT_IMG VERBOSE=true USE_KIND_CLUSTER=false SKIP_ES_EXTERNAL=true JAEGER_OLM=true KAFKA_OLM=true PROMETHEUS_OLM=true CI=true PIPELINE=true E2E_TESTS_TIMEOUT=$TIMEOUT
