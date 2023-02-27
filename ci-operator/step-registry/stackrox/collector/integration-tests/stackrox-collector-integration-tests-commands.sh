#!/usr/bin/env bash

set -eo pipefail

source .openshift-ci/jobs/integration-tests/env.sh

env

.openshift-ci/scripts/gcloud-init.sh

if [[ "${BENCHMARK_ONLY}" == "true" ]]; then
    .openshift-ci/jobs/integration-tests/run-benchmarks.sh
else
    .openshift-ci/jobs/integration-tests/run-integration-tests.sh
fi
