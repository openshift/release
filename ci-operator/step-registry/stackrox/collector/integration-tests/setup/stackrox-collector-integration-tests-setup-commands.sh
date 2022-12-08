#!/usr/bin/env bash

set -eo pipefail

source .openshift-ci/jobs/integration-tests/env.sh

.openshift-ci/scripts/gcloud-init.sh

if [[ "${BENCHMARK_ONLY}" == "true" ]]; then
    make -C ansible BUILD_TYPE=ci create-benchmark-vms
else
    make -C ansible BUILD_TYPE=ci create-vms
fi
